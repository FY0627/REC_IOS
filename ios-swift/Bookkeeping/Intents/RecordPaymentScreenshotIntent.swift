import AppIntents
import Foundation
import UniformTypeIdentifiers
import BKBackend
import BKModel

/// 「记录付款截图」（ADR 0021）：快捷指令把微信、支付宝付款页的截图交给 App，在手机上识别文字、入账。
///
/// 用法：快捷指令「截屏 → 记录付款截图」，设到轻点背面，付完款敲两下背面。以前的截图在 App 的「记一笔」里从相册选。
/// 也接受「从图像中提取文本」得到的文字，一行一行，和截图一样解析。
/// 和「记录银行动账通知」一样在后台执行，不打开 App、不弹对话框；结果发记账结果通知（「我的 › 通知」）。
/// 截图识别完就丢掉，只保存识别出的文字（和短信一样按保留期限清理），用来核对和处理待处理
struct RecordPaymentScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "记录付款截图"
    static let description = IntentDescription(
        "识别微信、支付宝付款页的截图并记账。在本机识别，不联网，截图不保存。",
        categoryName: "自动记账",
        searchKeywords: ["记账", "截图", "截屏", "微信", "支付宝", "付款"]
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = true

    @Parameter(
        title: "截图",
        description: "选上一步「截屏」的结果。",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile?

    @Parameter(title: "文字", description: "可选。已经识别出的文字，例如「从图像中提取文本」的结果；有截图时不用填。")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("记录\(\.$image)") {
            \.$text
        }
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let signposter = AppServices.signposter
        let state = signposter.beginInterval("Screenshot")
        defer { signposter.endInterval("Screenshot", state) }

        let backend: LedgerBackend
        do {
            backend = try AppServices.shared.backend()
        } catch {
            throw IntentFailure.storageUnavailable((error as? LocalizedError)?.errorDescription ?? L("无法打开本地账本"))
        }
        let result: IngestResult
        if let image {
            let reading = try await ScreenshotReader.read(image.data)
            result = try await backend.ingestScreenshot(lines: reading.lines, capturedAt: reading.capturedAt ?? Date())
        } else {
            result = try await backend.ingestScreenshot(text: text ?? "", capturedAt: Date())
        }
        // 日志只记录结果类别，不记录截图上的文字
        AppServices.logger.info("screenshot outcome=\(result.outcome.rawValue, privacy: .public) recorded=\(result.recordedCount) merged=\(result.mergedCount) pending=\(result.pendingCount)")
        await MainActor.run { NotificationCenter.default.post(name: .ledgerDidChange, object: nil) }
        await IngestNotifier.post(result, backend: backend, screenshot: true)
        return .result(value: result.summary)
    }
}
