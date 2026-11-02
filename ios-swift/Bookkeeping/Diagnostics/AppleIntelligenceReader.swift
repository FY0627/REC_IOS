import Foundation
import FoundationModels
import BKBackend
import BKModel

@Generable
enum NoticeAnswerDirection {
    case inflow
    case outflow
}

@Generable
enum NoticeAnswerKind {
    case purchase
    case salary
    case transferIn
    case transferOut
    case refund
    case repayment
    case withdrawal
    case deposit
    case interest
    case fee
    case other
}

@Generable
enum NoticeAnswerStatus {
    case posted
    case hold
    case failed
}

/// 要模型回答的内容。属性的顺序就是模型生成的顺序：先判断是不是交易
@Generable
struct NoticeAnswer: Sendable {
    @Guide(description: "True only when money moved or was held. False for verification codes, adverts, reminders, limit changes, statements and share orders.")
    var isTransaction: Bool

    @Guide(description: "The transaction amount, copied from the notice, without the currency. Never the balance, available limit or fee.")
    var amount: String?

    @Guide(description: "ISO 4217 code of the amount, such as CNY, HKD, USD, JPY.")
    var currency: String?

    @Guide(description: "inflow when money comes into the user's account, including refunds and card repayments.")
    var direction: NoticeAnswerDirection?

    var kind: NoticeAnswerKind?

    @Guide(description: "hold for pre-authorisations and frozen funds, failed when the payment did not go through.")
    var status: NoticeAnswerStatus?

    @Guide(description: "Last 3 or 4 digits of the user's own card or account, copied from the notice. Never the other party's account or a phone number.")
    var cardTail: String?

    @Guide(description: "The merchant or the other person, copied from the notice. Not the user's bank.")
    var counterparty: String?

    var reading: NoticeReading {
        NoticeReading(
            isTransaction: isTransaction, amount: amount, currency: currency, direction: direction.map(\.flow), kind: kind?.transactionKind,
            status: status?.settlement, cardTail: cardTail, counterparty: counterparty
        )
    }
}

private extension NoticeAnswerDirection {
    var flow: FlowDirection {
        switch self {
        case .inflow: .inflow
        case .outflow: .outflow
        }
    }
}

private extension NoticeAnswerKind {
    var transactionKind: TransactionKind {
        switch self {
        case .purchase: .purchase
        case .salary: .salary
        case .transferIn: .transferIn
        case .transferOut: .transferOut
        case .refund: .refund
        case .repayment: .repayment
        case .withdrawal: .withdrawal
        case .deposit: .deposit
        case .interest: .interestIncome
        case .fee: .fee
        case .other: .other
        }
    }
}

private extension NoticeAnswerStatus {
    var settlement: SettlementStatus {
        switch self {
        case .posted: .posted
        case .hold: .hold
        case .failed: .failed
        }
    }
}

/// 用手机上的苹果智能模型读通知，只给「苹果智能试读」页面用，还没有接到入账流程。不联网。
enum AppleIntelligenceReader {
    struct Status: Sendable {
        var available: Bool
        var detail: String
        /// 模型一次能处理多少 token；只有模型可用时才读得到
        var contextSize: Int?
        var languages: [(name: String, supported: Bool)]

        /// 复制结果时写在最前面
        var summary: [String] {
            var lines = ["模型：\(detail)"]
            if let contextSize { lines.append("上下文：\(contextSize)") }
            if !languages.isEmpty {
                lines.append("语言：" + languages.map { "\($0.name)\($0.supported ? "支持" : "不支持")" }.joined(separator: "，"))
            }
            return lines
        }
    }

    /// 一条通知最多给模型多少个字。短信都够；长邮件后面多半是页脚
    private static let maxLength = 2_000

    static func status() -> Status {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let languages = [("简体中文", "zh-Hans"), ("繁体中文", "zh-Hant"), ("英文", "en")].map { name, identifier in
                (name: name, supported: model.supportsLocale(Locale(identifier: identifier)))
            }
            return Status(available: true, detail: "可用", contextSize: model.contextSize, languages: languages)
        case .unavailable(.deviceNotEligible):
            return Status(available: false, detail: "这台手机不支持", contextSize: nil, languages: [])
        case .unavailable(.appleIntelligenceNotEnabled):
            return Status(available: false, detail: "没有打开 Apple 智能", contextSize: nil, languages: [])
        case .unavailable(.modelNotReady):
            return Status(available: false, detail: "模型还没下载好", contextSize: nil, languages: [])
        case .unavailable(let other):
            return Status(available: false, detail: "不可用：\(other)", contextSize: nil, languages: [])
        }
    }

    /// 每条通知用一个新的会话，互不影响。失败时不重试，把原因交给页面显示
    static func read(_ text: String) async -> (reading: NoticeReading?, failure: String?) {
        let notice = String(MessageParser.cleaned(text, source: .auto).prefix(maxLength))
        let session = LanguageModelSession(instructions: """
            You read one bank, card or wallet notice and report what it says. \
            The notice may be in Simplified Chinese, Traditional Chinese or English. \
            Copy values from the notice. Never calculate or guess, and leave a field empty when the notice does not state it. \
            When an amount is shown in two currencies, report the first one.
            """)
        do {
            let response = try await session.respond(
                generating: NoticeAnswer.self, includeSchemaInPrompt: true,
                options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: nil)
            ) {
                notice
            }
            return (response.content.reading, nil)
        } catch {
            return (nil, String(String(describing: error).prefix(60)))
        }
    }

    /// 同一条样本让规则和模型各读一遍
    static func trial(id: Int, sample: NoticeSamples.Sample) async -> NoticeTrialRow {
        let text = sample.text
        let rules = await Task.detached(priority: .userInitiated) {
            NoticeReading(rules: text, referenceDate: Date(), calendar: .current)
        }.value
        let clock = ContinuousClock()
        let started = clock.now
        let result = await read(text)
        let elapsed = started.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return NoticeTrialRow(id: id, sample: sample, rules: rules, model: result.reading, failure: result.failure, seconds: seconds)
    }
}
