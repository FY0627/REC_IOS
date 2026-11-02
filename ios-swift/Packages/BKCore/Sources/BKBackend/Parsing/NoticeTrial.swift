import Foundation
import BKModel

/// 一条通知读出来的内容。规则和苹果智能读出来的都放成这种形式，才能逐项比较。
public struct NoticeReading: Sendable, Hashable {
    public var isTransaction: Bool
    public var amount: String?
    public var currency: String?
    public var direction: FlowDirection?
    public var kind: TransactionKind?
    public var status: SettlementStatus?
    public var cardTail: String?
    public var counterparty: String?

    public init(
        isTransaction: Bool, amount: String? = nil, currency: String? = nil, direction: FlowDirection? = nil,
        kind: TransactionKind? = nil, status: SettlementStatus? = nil, cardTail: String? = nil, counterparty: String? = nil
    ) {
        self.isTransaction = isTransaction
        self.amount = amount
        self.currency = currency
        self.direction = direction
        self.kind = kind
        self.status = status
        self.cardTail = cardTail
        self.counterparty = counterparty
    }

    /// 规则读出来的第一笔，手续费不算
    public init(rules text: String, referenceDate: Date, calendar: Calendar) {
        let parsed = MessageParser.parse(MessageContext(text: text, source: .auto, sender: nil, subject: nil, referenceDate: referenceDate, calendar: calendar))
        guard parsed.classification == .transaction, let draft = (parsed.events.first { $0.draft.kind != .fee } ?? parsed.events.first)?.draft else {
            self.init(isTransaction: false)
            return
        }
        let currency = draft.amount.preferredCurrency ?? draft.amount.currencyCandidates.first
        self.init(
            isTransaction: true, amount: draft.amount.digits, currency: currency?.rawValue, direction: draft.direction,
            kind: draft.kind, status: draft.status, cardTail: draft.cardTail, counterparty: draft.counterparty
        )
    }

    /// 这一项显示成什么
    public func text(of field: NoticeField) -> String {
        let value: String?
        switch field {
        case .isTransaction: value = isTransaction ? "是" : "不是"
        case .amount: value = amount
        case .currency: value = currency
        case .direction: value = direction?.displayName
        case .kind: value = kind?.displayName
        case .status: value = status?.rawValue
        case .cardTail: value = cardTail
        case .counterparty: value = counterparty
        }
        return value ?? "无"
    }

    /// 金额、尾号在通知原文里找不到：不是读出来的，是模型编的
    public func invented(in text: String) -> [NoticeField] {
        let cleaned = MessageParser.cleaned(text, source: .auto).replacingOccurrences(of: ",", with: "")
        var found: [NoticeField] = []
        if let amount, !Self.amountPattern(amount).test(cleaned) { found.append(.amount) }
        if let cardTail, !cleaned.contains(cardTail) { found.append(.cardTail) }
        return found
    }

    /// 同一个金额的几种写法：`2` 和 `2.00`、`0.8` 和 `0.80`、`1200` 和 `1,200`
    private static func amountPattern(_ amount: String) -> Rx {
        var number = amount.filter { $0.isNumber || $0 == "." }
        if number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        let trailing = number.contains(".") ? "0*" : #"(?:\.0+)?"#
        return Rx(#"(?<![\d.])"# + NSRegularExpression.escapedPattern(for: number) + trailing + #"(?!\d)"#)
    }
}

/// 逐项比较的项目
public enum NoticeField: String, CaseIterable, Sendable, Identifiable {
    case isTransaction = "是否交易"
    case amount = "金额"
    case currency = "币种"
    case direction = "方向"
    case kind = "性质"
    case status = "状态"
    case cardTail = "尾号"
    case counterparty = "对方"

    public var id: Self { self }
}

public struct NoticeDifference: Sendable, Hashable, Identifiable {
    public var field: NoticeField
    public var expected: String
    public var actual: String

    public var id: NoticeField { field }
}

public enum NoticeComparison {
    /// 这一项读对了没有。答案里没有这一项时是 nil，不算分
    public static func matches(_ field: NoticeField, answer: NoticeReading, reading: NoticeReading) -> Bool? {
        switch field {
        case .isTransaction: answer.isTransaction == reading.isTransaction
        case .amount: answer.amount.map { sameAmount($0, reading.amount) }
        case .currency: answer.currency.map { $0 == reading.currency?.uppercased() }
        case .direction: answer.direction.map { $0 == reading.direction }
        // 通知没写性质时答案是「其他」，读成哪一种都不算错
        case .kind: answer.kind.flatMap { $0 == .other ? nil : $0 == reading.kind }
        case .status: answer.status.map { $0 == reading.status }
        case .cardTail: answer.cardTail.map { sameTail($0, reading.cardTail) }
        case .counterparty: answer.counterparty.map { sameName($0, reading.counterparty) }
        }
    }

    public static func differences(answer: NoticeReading, reading: NoticeReading) -> [NoticeDifference] {
        NoticeField.allCases.compactMap { field in
            guard matches(field, answer: answer, reading: reading) == false else { return nil }
            return NoticeDifference(field: field, expected: answer.text(of: field), actual: reading.text(of: field))
        }
    }

    private static func sameAmount(_ a: String, _ b: String?) -> Bool {
        guard let b, let left = minorUnits(a), let right = minorUnits(b) else { return false }
        return left == right
    }

    private static func minorUnits(_ text: String) -> Int64? {
        try? AmountParser.minorUnits(text.filter { $0.isNumber || $0 == "." || $0 == "," }, exponent: 2).get()
    }

    /// 邮储只写后三位
    private static func sameTail(_ tail: String, _ other: String?) -> Bool {
        guard let other, other.count >= 3 else { return false }
        return tail.hasSuffix(other)
    }

    /// 商户名称前后多几个字（城市、国家）不算错
    private static func sameName(_ name: String, _ other: String?) -> Bool {
        let left = BankCatalog.normalize(name), right = BankCatalog.normalize(other ?? "")
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.contains(right) || right.contains(left)
    }
}

extension NoticeSamples.Sample {
    /// 写在 `expected` 里的答案。尾号是入账时配到的卡，通知里没写的不算
    public var answer: NoticeReading {
        let parts = expected.split(separator: " ", maxSplits: 6).map(String.init)
        guard parts.count >= 6, parts[0] == "入账" else { return NoticeReading(isTransaction: false) }
        var counterparty: String?
        if parts.count > 6, parts[6].hasPrefix("@") {
            counterparty = parts[6].components(separatedBy: " 实扣")[0].dropFirst().description
        }
        return NoticeReading(
            isTransaction: true, amount: String(parts[2].dropFirst()), currency: parts[3], direction: parts[2].hasPrefix("+") ? .inflow : .outflow,
            kind: TransactionKind(rawValue: parts[4]), status: SettlementStatus(rawValue: parts[5]),
            cardTail: text.contains(parts[1]) ? parts[1] : nil, counterparty: counterparty
        )
    }
}

/// 「苹果智能试读」里一条样本的结果
public struct NoticeTrialRow: Sendable, Identifiable {
    /// 第几条，从 1 开始
    public var id: Int
    public var text: String
    public var answer: NoticeReading
    public var rules: NoticeReading
    /// 苹果智能读出来的；读取失败时是 nil
    public var model: NoticeReading?
    /// 读取失败的原因
    public var failure: String?
    public var seconds: Double

    public init(id: Int, sample: NoticeSamples.Sample, rules: NoticeReading, model: NoticeReading?, failure: String?, seconds: Double) {
        self.id = id
        text = sample.text
        answer = sample.answer
        self.rules = rules
        self.model = model
        self.failure = failure
        self.seconds = seconds
    }

    public var modelDifferences: [NoticeDifference] {
        model.map { NoticeComparison.differences(answer: answer, reading: $0) } ?? []
    }

    /// 金额、尾号不在原文里的项目
    public var invented: [NoticeField] { model?.invented(in: text) ?? [] }
}

public struct NoticeFieldScore: Sendable, Identifiable {
    public var field: NoticeField
    public var rulesRight = 0
    public var rulesTotal = 0
    public var modelRight = 0
    public var modelTotal = 0

    public var id: NoticeField { field }
}

public enum NoticeTrial {
    public static func scores(_ rows: [NoticeTrialRow]) -> [NoticeFieldScore] {
        NoticeField.allCases.map { field in
            var score = NoticeFieldScore(field: field)
            for row in rows {
                if let right = NoticeComparison.matches(field, answer: row.answer, reading: row.rules) {
                    score.rulesTotal += 1
                    if right { score.rulesRight += 1 }
                }
                if let model = row.model, let right = NoticeComparison.matches(field, answer: row.answer, reading: model) {
                    score.modelTotal += 1
                    if right { score.modelRight += 1 }
                }
            }
            return score
        }
    }

    /// 用时只算读成功的：读取失败往往是马上返回的
    public static func timing(_ rows: [NoticeTrialRow]) -> (average: Double, slowest: Double)? {
        let times = rows.filter { $0.model != nil }.map(\.seconds)
        guard let slowest = times.max() else { return nil }
        return (times.reduce(0, +) / Double(times.count), slowest)
    }

    /// 复制出来发给别人看的结果。样本是脱敏的，这里只写编号和读错的项目
    public static func report(_ rows: [NoticeTrialRow], header: [String]) -> String {
        var lines = header
        lines.append("样本 \(rows.count) 条，读取失败 \(rows.filter { $0.model == nil }.count) 条，金额或尾号不在原文里 \(rows.filter { !$0.invented.isEmpty }.count) 条")
        if let timing = timing(rows) {
            lines.append(String(format: "平均 %.1f 秒，最慢 %.1f 秒", timing.average, timing.slowest))
        }
        for score in scores(rows) {
            lines.append("\(score.field.rawValue)：规则 \(score.rulesRight)/\(score.rulesTotal)，苹果智能 \(score.modelRight)/\(score.modelTotal)")
        }
        for row in rows {
            if let failure = row.failure { lines.append("#\(row.id) 读取失败：\(failure)") }
            for difference in row.modelDifferences {
                lines.append("#\(row.id) \(difference.field.rawValue)：应为 \(difference.expected)，读成 \(difference.actual)")
            }
            if !row.invented.isEmpty {
                lines.append("#\(row.id) 不在原文里：" + row.invented.map(\.rawValue).joined(separator: "、"))
            }
        }
        return lines.joined(separator: "\n")
    }
}
