import AppIntents
import Foundation
import UserNotifications
import BKBackend
import BKModel

/// 快捷指令自动化调用：把「获取 URL 内容」下载的汇率数据导入 App，App 自己不联网。
///
/// 「我的」里给的共享快捷指令就是「获取 URL 内容」（汇率地址）→「导入汇率」；用户再建一个「打开 REC 时」运行它的自动化。
/// 共享的快捷指令按安装时的 App 标识（含签名团队后缀）找到这个动作，换了签名要重新共享。
/// 和「记录银行动账通知」一样完全在后台执行，不打开 App、不弹出交互；导入成功后发一条本机通知（「我的 › 通知」里可以关掉）。
struct ImportExchangeRatesIntent: AppIntent {
    static let title: LocalizedStringResource = "导入汇率"
    static let description = IntentDescription(
        "把「获取 URL 内容」下载的汇率数据导入 REC，资产页按主要币种换算净资产。App 自己不联网。",
        categoryName: "汇率",
        searchKeywords: ["汇率", "货币", "换算", "外币"]
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = true

    @Parameter(
        title: "汇率数据",
        description: "选择上一步「获取 URL 内容」的结果（URL 的内容）。",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var content: String?

    static var parameterSummary: some ParameterSummary {
        Summary("导入\(\.$content)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let content, !content.isEmpty else { throw ImportFailure.empty }
        let rates: ExchangeRates
        do {
            rates = try ExchangeRateFeed.parse(Data(content.utf8), fetchedAt: Date())
        } catch {
            throw ImportFailure.unreadable
        }
        ExchangeRateStore.save(rates)
        // 每天的完整汇率表都留着：外币交易按交易当天的汇率估算扣款。账本暂时打不开（开机后没解锁过）时只更新最新汇率
        if let backend = try? AppServices.shared.backend() {
            _ = try? await backend.saveExchangeRates(rates)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .exchangeRatesDidChange, object: nil)
            // 外币交易的估算扣款可能变了：余额重新推算
            NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        }
        AppServices.logger.info("exchange rates imported count=\(rates.rates.count)")
        if Self.notifies { await Self.notifyImported(rates) }
        return .result(value: "已导入 \(rates.rates.count) 个币种的汇率")
    }

    /// 「我的 › 通知 › 导入汇率」：默认打开
    static let notifyKey = "notify.ratesImported"
    static var notifies: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }

    /// 没有通知权限时系统不显示。同一个标识：通知中心里只留最新一条
    private static func notifyImported(_ rates: ExchangeRates) async {
        let center = UNUserNotificationCenter.current()
        // App 正在前台时（例如「打开 REC 时」触发）也显示横幅
        center.delegate = NotificationPresenter.shared
        let content = UNMutableNotificationContent()
        content.title = "汇率已更新"
        content.body = "已导入 \(rates.rates.count) 个币种的汇率，数据更新于\(Fmt.dateTime(rates.updatedAt))"
        content.threadIdentifier = "fx"
        try? await center.add(UNNotificationRequest(identifier: "fx-imported", content: content, trigger: nil))
    }
}

enum ImportFailure: Error, CustomLocalizedStringResourceConvertible {
    case empty
    case unreadable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: "没有收到汇率数据。请在「汇率数据」里选择「获取 URL 内容」的结果。"
        case .unreadable: "无法识别汇率数据。请确认「获取 URL 内容」的地址是 open.er-api.com 的汇率地址。"
        }
    }
}
