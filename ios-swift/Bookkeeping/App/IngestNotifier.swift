import Foundation
import UserNotifications
import BKBackend
import BKModel

/// 记账结果通知：自动化入账后发一条本机通知，例如「尾号 1234 卡，消费，¥128.00，记账成功」。
///
/// 是本机通知（UserNotifications），不经过服务器，App 也不联网。
/// 在「我的 › 通知 › 记账结果」里选择全部通知、只通知失败或关闭；第一次打开时请求通知权限。
/// 同一笔交易的另一来源（短信 + 邮件）合并、重复输入、验证码和营销短信不发通知。
///
/// 选「全部」时，还没分类、或者自动归类的流水带几个分类按钮：点了不打开 App，在后台保存（`handle`），锁屏时也能写
/// （账本的保护等级是 `completeUntilFirstUserAuthentication`，和自动化入账一样）。
enum IngestNotifier {
    enum Mode: String, CaseIterable, Identifiable {
        case all
        case failures
        case off

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .failures: "仅失败"
            case .off: "关闭"
            }
        }
    }

    static let modeKey = "notify.ingestResult"

    static var mode: Mode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init) ?? .off
    }

    /// 请求通知权限；用户拒绝时返回 false
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func post(_ result: IngestResult, backend: LedgerBackend) async {
        let mode = mode
        guard mode != .off else { return }
        let center = UNUserNotificationCenter.current()
        for (index, item) in result.items.enumerated() {
            let suggestions = await categorySuggestions(for: item, backend: backend)
            guard let body = message(item, failuresOnly: mode == .failures, autoCategory: suggestions.autoCategory?.name) else { continue }
            let content = UNMutableNotificationContent()
            content.body = body
            content.threadIdentifier = "ingest"
            // 银行短信本身已经响过，这条通知不再出声
            content.sound = nil
            if let recordID = item.recordID, !suggestions.categories.isEmpty {
                let category = notificationCategory(suggestions.categories)
                await register(category)
                content.categoryIdentifier = category.identifier
                content.userInfo = [recordIDKey: recordID]
            }
            let id = "ingest-\(result.ingestID ?? UUID().uuidString)-\(index)"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: 通知上选分类

    private static let recordIDKey = "recordID"
    private static let pickPrefix = "pick."

    /// 只有选「全部」时才有成功的通知，才带按钮
    private static func categorySuggestions(for item: IngestItem, backend: LedgerBackend) async -> CategorySuggestions {
        guard mode == .all, item.result == .recorded, let recordID = item.recordID else { return CategorySuggestions() }
        return (try? await backend.categorySuggestions(recordID: recordID)) ?? CategorySuggestions()
    }

    /// 按钮写在通知类别上。不设 `.foreground` 就不打开 App，不设 `.authenticationRequired` 就不用解锁。
    /// 同一组候选共用一个类别；分类改了名称或图标要换一个，系统不会更新已经注册的按钮
    private static func notificationCategory(_ categories: [LedgerCategory]) -> UNNotificationCategory {
        let actions = categories.map { category in
            UNNotificationAction(
                identifier: pickPrefix + category.id, title: category.name, options: [],
                icon: UNNotificationActionIcon(systemImageName: category.symbol)
            )
        }
        let identifier = "ingest|" + categories.map { "\($0.id)=\($0.name)=\($0.symbol)" }.joined(separator: "|")
        return UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
    }

    /// 候选每笔不同，所以发通知前才注册这一组，不在启动时注册（ADR 0017）。
    /// 注册是替换全部，所以留下还在通知中心的通知用到的类别。注册没有完成回调，读回来看到了才发；
    /// 一直看不到时照发，这条通知只是没有按钮，这笔还在待分类
    private static func register(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map(\.request.content.categoryIdentifier)
        let kept = await center.notificationCategories().filter { delivered.contains($0.identifier) }
        center.setNotificationCategories(kept.union([category]))
        for _ in 0..<5 {
            let registered = await center.notificationCategories()
            if registered.contains(where: { $0.identifier == category.identifier }) { return }
            try? await Task.sleep(for: .milliseconds(50))
            // 另一笔同时注册时可能盖掉了这一组，补上
            center.setNotificationCategories(registered.union([category]))
        }
    }

    /// 点了通知上的分类按钮：系统在后台拉起 App 调到这里，写完才返回。
    /// 写不进去（开机后还没解锁过、流水或分类已经删了）时这笔留在原处，下次打开 App 再选
    static func handle(_ response: UNNotificationResponse) async {
        guard response.actionIdentifier.hasPrefix(pickPrefix),
              let recordID = response.notification.request.content.userInfo[recordIDKey] as? String else { return }
        let categoryID = String(response.actionIdentifier.dropFirst(pickPrefix.count))
        do {
            // App 可能是被这个按钮拉起来的：打开账本（含迁移）放在后台线程
            let backend = try await Task.detached(priority: .userInitiated) { try AppServices.shared.backend() }.value
            try await backend.setCategory(recordID: recordID, categoryID: categoryID)
            await MainActor.run { NotificationCenter.default.post(name: .ledgerDidChange, object: nil) }
        } catch {
            AppServices.logger.error("pick category failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// 尾号 1234 卡，消费，¥128.00，记账成功
    /// 尾号 1234 卡，消费，¥128.00，记账成功，已归到「午餐」
    /// 尾号 1234 卡，消费，128.00，记账失败：没有与尾号匹配的账户
    static func message(_ item: IngestItem, failuresOnly: Bool, autoCategory: String? = nil) -> String? {
        let succeeded: Bool
        var outcome: String
        switch item.result {
        case .recorded:
            succeeded = true
            outcome = "记账成功"
            if let autoCategory { outcome += "，已归到「\(autoCategory)」" }
        case .merged:
            return nil
        case .pending(let reason):
            succeeded = false
            outcome = "记账失败：\(reason.displayName)，已放入待处理"
        }
        if failuresOnly, succeeded { return nil }
        if item.kind == nil, item.amountText == nil, item.amountMinor == nil {
            return "收到一条无法识别的银行通知，已放入待处理"
        }

        var parts: [String] = []
        parts.append(item.cardTail.map { "尾号 \($0) 卡" } ?? "未知尾号的卡")
        if let kind = item.kind {
            var action = kind.displayName
            if let status = item.status, status != .posted { action += "（\(status.displayName)）" }
            parts.append(action)
        }
        if let amount = amountText(item) { parts.append(amount) }
        parts.append(outcome)
        return parts.joined(separator: "，")
    }

    private static func amountText(_ item: IngestItem) -> String? {
        if let minor = item.amountMinor, let currency = item.currency {
            return Fmt.money(minor, currency)
        }
        guard let digits = item.amountText else { return nil }
        return item.currency.map { "\(digits) \($0.rawValue)" } ?? digits
    }
}

/// 通知的代理：App 在前台时也显示记账结果通知的横幅；收到通知上的分类按钮。启动时设好（`AppDelegate`）。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await IngestNotifier.handle(response)
    }
}
