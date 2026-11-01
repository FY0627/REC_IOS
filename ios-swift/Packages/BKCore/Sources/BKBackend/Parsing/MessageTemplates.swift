import Foundation
import BKModel

/// 用户模板：从一条通知做出写法；用写法认出新通知里的金额、尾号、对方。
///
/// 做模板时，用户在整理过的正文（`MessageParser.cleaned`）里圈出金额，可选圈出尾号和对方。
/// 模板只取圈出内容所在的句子（前后文字太少时往前多取几句），其他数字一律换成「任意数字」。
/// 认的时候文字要一致（空白多少不限、不分大小写），数字可以不同。
public enum MessageTemplates {
    public enum BuildError: Error, Equatable, Sendable {
        /// 圈出的金额里没有数字
        case invalidAmount
        /// 圈出的尾号里不足 4 位数字
        case invalidCardTail
        case emptyCounterparty
        /// 圈出的几处有重叠
        case overlapping
        /// 前后文字太少，会认错别的通知
        case tooGeneric

        public var message: String {
            switch self {
            case .invalidAmount: "圈出的金额里没有数字"
            case .invalidCardTail: "圈出的尾号至少要有 4 位数字"
            case .emptyCounterparty: "圈出的对方是空的"
            case .overlapping: "金额、尾号、对方圈出的位置不能重叠"
            case .tooGeneric: "这条通知的文字太少，做成模板会认错别的通知"
            }
        }
    }

    /// 用模板从一条通知里认出的内容
    public struct Hit: Sendable, Hashable {
        public var amount: AmountText
        public var cardTail: String?
        public var counterparty: String?
        /// 模板对上的那段原文（展示给用户核对）
        public var snippet: String
    }

    /// 至少要有这么多个文字（汉字、字母），模板才不会对上无关的通知
    static let minimumLetters = 8

    private static let numberToken = Rx(#"[0-9](?:[0-9*xX•.,:'/\-]*[0-9*xX•])?"#)
    private static let amountDigits = Rx(#"[0-9](?:[0-9,.']*[0-9])?"#)
    private static let tailRun = Rx(#"[0-9*xX•\-]*[0-9]{4}"#)
    private static let sentenceBreaks: Set<unichar> = Set("。；;!！?？\n".utf16)

    // MARK: 做模板

    /// - Parameters:
    ///   - sample: 整理过的正文
    ///   - amount / cardTail / counterparty: 用户圈出的位置，按 UTF-16 计（与 `NSString`、`UITextView` 一致）
    public static func build(sample: String, amount: NSRange, cardTail: NSRange?, counterparty: NSRange?) -> Result<[TemplatePiece], BuildError> {
        let ns = NSString(string: sample)
        func inBounds(_ r: NSRange) -> Bool { r.location != NSNotFound && r.length > 0 && NSMaxRange(r) <= ns.length }

        // 圈得宽一点也可以：只取里面真正的金额 / 尾号，对方去掉两边的空白和引号
        guard inBounds(amount), let amountRange = amountDigits.first(ns, in: amount)?.range else { return .failure(.invalidAmount) }
        var marks: [(range: NSRange, piece: TemplatePiece)] = [(amountRange, .amount)]
        if let cardTail {
            guard inBounds(cardTail), let run = tailRun.matches(ns, in: cardTail).last?.range else { return .failure(.invalidCardTail) }
            marks.append((run, .cardTail))
        }
        if let counterparty {
            guard inBounds(counterparty), let trimmed = trim(counterparty, in: ns) else { return .failure(.emptyCounterparty) }
            marks.append((trimmed, .counterparty))
        }
        marks.sort { $0.range.location < $1.range.location }
        for i in marks.indices.dropFirst() where marks[i].range.location < NSMaxRange(marks[i - 1].range) {
            return .failure(.overlapping)
        }

        // 圈出内容所在的句子；文字太少时往前多取几句（例如邮件里金额单独一行）
        var start = sentenceStart(before: marks[0].range.location, in: ns)
        var end = NSMaxRange(marks[marks.count - 1].range)
        while end < ns.length, !sentenceBreaks.contains(ns.character(at: end)) { end += 1 }
        func letterCount() -> Int {
            var count = 0
            var cursor = start
            for mark in marks {
                count += letters(in: ns.substring(with: NSRange(location: cursor, length: mark.range.location - cursor)))
                cursor = NSMaxRange(mark.range)
            }
            return count + letters(in: ns.substring(with: NSRange(location: cursor, length: end - cursor)))
        }
        while letterCount() < minimumLetters, start > 0 {
            start = sentenceStart(before: start - 1, in: ns)
        }
        guard letterCount() >= minimumLetters else { return .failure(.tooGeneric) }

        var pieces: [TemplatePiece] = []
        var cursor = start
        for mark in marks {
            appendPlain(NSRange(location: cursor, length: mark.range.location - cursor), in: ns, to: &pieces)
            pieces.append(mark.piece)
            cursor = NSMaxRange(mark.range)
        }
        appendPlain(NSRange(location: cursor, length: end - cursor), in: ns, to: &pieces)
        return .success(trimEdges(pieces))
    }

    private static func sentenceStart(before location: Int, in ns: NSString) -> Int {
        var start = location
        while start > 0, !sentenceBreaks.contains(ns.character(at: start - 1)) { start -= 1 }
        // 跳过句首的换行和空白
        while start < location, let scalar = Unicode.Scalar(ns.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(scalar) { start += 1 }
        return start
    }

    private static func letters(in text: String) -> Int {
        text.filter { $0.isLetter }.count
    }

    /// 去掉两边的空白、引号和标点；打码用的 `*` `•` 保留（例如「张*三」「陈**」）
    private static let counterpartyEdges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "*•"))

    private static func trim(_ range: NSRange, in ns: NSString) -> NSRange? {
        let text = ns.substring(with: range)
        let leading = text.prefix { $0.unicodeScalars.allSatisfy(counterpartyEdges.contains) }
        let rest = text.dropFirst(leading.count)
        let trailing = rest.reversed().prefix { $0.unicodeScalars.allSatisfy(counterpartyEdges.contains) }
        let core = rest.dropLast(trailing.count)
        guard !core.isEmpty else { return nil }
        return NSRange(location: range.location + String(leading).utf16.count, length: String(core).utf16.count)
    }

    /// 没圈出的部分：数字换成「任意数字」，其余是文字
    private static func appendPlain(_ range: NSRange, in ns: NSString, to pieces: inout [TemplatePiece]) {
        guard range.length > 0 else { return }
        var cursor = range.location
        for token in numberToken.matches(ns, in: range) {
            if token.range.location > cursor {
                pieces.append(.text(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))))
            }
            pieces.append(.anyNumber)
            cursor = NSMaxRange(token.range)
        }
        if cursor < NSMaxRange(range) {
            pieces.append(.text(ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))))
        }
    }

    private static func trimEdges(_ pieces: [TemplatePiece]) -> [TemplatePiece] {
        var pieces = pieces
        if case .text(let text)? = pieces.first {
            let trimmed = String(text.drop { $0.isWhitespace })
            if trimmed.isEmpty { pieces.removeFirst() } else { pieces[0] = .text(trimmed) }
        }
        if case .text(let text)? = pieces.last {
            let trimmed = String(text.reversed().drop { $0.isWhitespace }.reversed())
            if trimmed.isEmpty { pieces.removeLast() } else { pieces[pieces.count - 1] = .text(trimmed) }
        }
        return pieces
    }

    /// 模板还原成的一条示例通知，圈好的位置按 UTF-16 计
    public struct Sample: Sendable, Hashable {
        public var text: String
        public var amount: NSRange?
        public var cardTail: NSRange?
        public var counterparty: NSRange?
    }

    /// 编辑已有的模板：模板里没有原文，把写法还原成一条示例通知再让用户改。
    /// 金额写 100.00、尾号 1234、对方写「对方」、其他数字写 0；用它再 `build` 得到同样的写法
    public static func sample(_ pieces: [TemplatePiece]) -> Sample {
        var result = Sample(text: "")
        func append(_ part: String) -> NSRange {
            let range = NSRange(location: result.text.utf16.count, length: part.utf16.count)
            result.text += part
            return range
        }
        for piece in pieces {
            switch piece {
            case .text(let text): _ = append(text)
            case .anyNumber: _ = append("0")
            case .amount: result.amount = append("100.00")
            case .cardTail: result.cardTail = append("1234")
            case .counterparty: result.counterparty = append("对方")
            }
        }
        return result
    }

    // MARK: 认通知

    /// 模板对应的正则：文字原样（空白多少不限），数字任意，圈出的位置是捕获组
    static func regex(_ pieces: [TemplatePiece]) -> NSRegularExpression? {
        var pattern = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let text): pattern += literal(text)
            case .anyNumber: pattern += #"[0-9][0-9*xX•.,:'/\-]*"#
            case .amount: pattern += #"([0-9](?:[0-9,.']*[0-9])?)"#
            case .cardTail: pattern += #"[0-9*xX•\-]*?([0-9]{4})(?![0-9])"#
            case .counterparty: pattern += index == pieces.count - 1 ? #"([^\n]+)"# : #"([^\n]+?)"#
            }
        }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func literal(_ text: String) -> String {
        var pattern = ""
        var space = false
        for character in text {
            if character.isWhitespace {
                space = true
                continue
            }
            if space || pattern.isEmpty { pattern += #"\s*"# }
            space = false
            pattern += NSRegularExpression.escapedPattern(for: String(character))
        }
        return pattern + #"\s*"#
    }

    /// 用模板认一条整理过的正文。认不出、或者认出的金额不是数字时返回 nil。
    public static func match(_ template: MessageTemplate, in text: String) -> Hit? {
        guard template.pieces.contains(.amount), let re = regex(template.pieces) else { return nil }
        let ns = NSString(string: text)
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var amountRange: NSRange?
        var tail: String?
        var counterparty: String?
        var group = 1
        for piece in template.pieces {
            switch piece {
            case .amount: amountRange = m.range(at: group)
            case .cardTail: tail = m.range(at: group).location == NSNotFound ? nil : ns.substring(with: m.range(at: group))
            case .counterparty:
                let r = m.range(at: group)
                if r.location != NSNotFound { counterparty = trim(r, in: ns).map { ns.substring(with: $0) } }
            case .text, .anyNumber: continue
            }
            group += 1
        }
        guard let amountRange, amountRange.location != NSNotFound else { return nil }
        let digits = ns.substring(with: amountRange)
        if case .failure(.invalid) = AmountParser.minorUnits(digits, exponent: 2) { return nil }

        let beforeStart = max(0, amountRange.location - 10)
        let before = ns.substring(with: NSRange(location: beforeStart, length: amountRange.location - beforeStart))
        let after = ns.substring(with: NSRange(location: NSMaxRange(amountRange), length: min(12, ns.length - NSMaxRange(amountRange))))
        let chinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let currency = CurrencyTokens.combine(CurrencyTokens.prefix(in: before), CurrencyTokens.suffix(in: after), chineseText: chinese)
        return Hit(
            amount: AmountText(digits: digits, currencyCandidates: currency.candidates, preferredCurrency: currency.preferred),
            cardTail: tail, counterparty: counterparty, snippet: String(ns.substring(with: m.range).prefix(160))
        )
    }

    /// 第一个认得出这条正文的模板
    public static func firstHit(_ templates: [MessageTemplate], in text: String) -> (template: MessageTemplate, hit: Hit)? {
        for template in templates {
            if let hit = match(template, in: text) { return (template, hit) }
        }
        return nil
    }

    /// 模板认出的一笔交易：性质和方向由用户做模板时选定，时间和交易参考号用通用读法从正文里找
    public static func draft(_ hit: Hit, template: MessageTemplate, parsed: ParsedMessage, partIndex: Int) -> EventDraft {
        EventDraft(
            amount: hit.amount, direction: template.direction, kind: template.kind, status: .posted,
            counterparty: hit.counterparty, cardTail: hit.cardTail, counterpartyTail: nil, transactionTime: parsed.firstTime,
            bankReference: parsed.onlyReference, balanceAfter: nil, includedFee: nil, isSplitFee: false, partIndex: partIndex,
            bankHint: parsed.bankHint, walletHint: parsed.walletHint, evidenceSnippet: hit.snippet
        )
    }
}
