import AppIntents
import Foundation
import BKBackend
import BKModel

/// 快捷指令自动化调用的唯一动作：把收到的短信 / 邮件交给本机解析并入账。
///
/// - `supportedModes = .background`：完全在后台执行，不打开 App、不切换前台应用、
///   不在锁屏时拉起界面（iOS 26 起的正式接口，替代已弃用的 `openAppWhenRun`）。
/// - 不实现 `ProvidesDialog`、不调用 `requestValue` / `requestConfirmation`，
///   所以成功时不会弹出 App 自己的任何交互；所有参数都是可选的，缺失时不会向用户追问。
/// - 系统自身的提示（例如自动化的「运行时通知」开关、首次授权）不受 App 控制，见文档说明。
struct RecordBankMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "记录银行动账通知"
    static let description = IntentDescription(
        "把收到的银行短信或邮件交给 REC，在本机解析、匹配账户、去重并入账。不会打开 App，也不联网。",
        categoryName: "自动记账",
        searchKeywords: ["记账", "银行", "短信", "邮件", "动账"]
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = true

    /// 自动连接上一步的输出：作为自动化的第一个动作时，快捷指令会尽量自动填入「快捷指令输入」，
    /// 用户只需确认（是否自动填入由系统决定，设置步骤里仍保留「确认」这一步）。
    @Parameter(
        title: "通知内容",
        description: "在自动化里选择「快捷指令输入」，或其中的「内容」。",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var content: String?

    /// 一个自动化同时用「信息」「电子邮件」「App 通知」触发时选「自动」
    @Parameter(title: "来源", default: .auto)
    var source: MessageSourceOption

    @Parameter(title: "发件人", description: "可选。短信发件号码或邮件发件地址，用来识别银行。")
    var sender: String?

    @Parameter(title: "主题", description: "可选。邮件主题。")
    var subject: String?

    @Parameter(title: "接收时间", description: "可选。系统提供的接收日期；没有就留空，App 不会用其他时间冒充。")
    var receivedAt: Date?

    @Parameter(title: "消息标识", description: "可选。系统提供的邮件 ID 等标识；没有就留空。")
    var messageID: String?

    @Parameter(title: "绑定账户", description: "可选。同尾号有多张卡时帮助匹配；正文里的尾号仍然优先。")
    var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$content)作为\(\.$source)记入账本") {
            \.$account
            \.$sender
            \.$subject
            \.$receivedAt
            \.$messageID
        }
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let signposter = AppServices.signposter
        let state = signposter.beginInterval("Ingest")
        defer { signposter.endInterval("Ingest", state) }

        let backend: LedgerBackend
        do {
            backend = try AppServices.shared.backend()
        } catch {
            throw IntentFailure.storageUnavailable((error as? LocalizedError)?.errorDescription ?? "无法打开本地账本")
        }
        let request = IngestRequest(
            text: content ?? "",
            source: source.model,
            sender: sender?.nilIfBlank,
            subject: subject?.nilIfBlank,
            receivedAt: receivedAt,
            messageID: messageID?.nilIfBlank,
            boundAccountID: account?.id
        )
        let result = try await backend.ingest(request)
        // 日志只记录结果类别，不记录正文、金额、发件人
        AppServices.logger.info("ingest outcome=\(result.outcome.rawValue, privacy: .public) class=\(result.classification.rawValue, privacy: .public) recorded=\(result.recordedCount) pending=\(result.pendingCount)")
        await MainActor.run { NotificationCenter.default.post(name: .ledgerDidChange, object: nil) }
        // 记账结果通知（「我的」里打开后才发）
        await IngestNotifier.post(result)
        return .result(value: result.summary)
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case storageUnavailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storageUnavailable(let message): "\(message)"
        }
    }
}

enum MessageSourceOption: String, AppEnum {
    case auto
    case sms
    case email
    case notification
    case other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "通知来源"
    static let caseDisplayRepresentations: [MessageSourceOption: DisplayRepresentation] = [
        .auto: "自动",
        .sms: "短信",
        .email: "邮件",
        .notification: "App 通知",
        .other: "其他文本",
    ]

    var model: SourceKind {
        switch self {
        case .auto: .auto
        case .sms: .sms
        case .email: .email
        case .notification: .notification
        case .other: .other
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
