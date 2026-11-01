import Foundation
import UserNotifications
import BKModel

/// 记账结果通知：自动化入账后发一条本机通知，例如「尾号 1234 卡，消费，¥128.00，记账成功」。
///
/// 是本机通知（UserNotifications），不经过服务器，App 也不联网。
/// 在「我的 › 通知 › 记账结果」里选择全部通知、只通知失败或关闭；第一次打开时请求通知权限。
/// 同一笔交易的另一来源（短信 + 邮件）合并、重复输入、验证码和营销短信不发通知。
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

    static func post(_ result: IngestResult) async {
        let mode = mode
        guard mode != .off else { return }
        let center = UNUserNotificationCenter.current()
        // App 正在前台时系统默认不显示通知横幅，由代理决定显示
        center.delegate = NotificationPresenter.shared
        for (index, item) in result.items.enumerated() {
            guard let body = message(item, failuresOnly: mode == .failures) else { continue }
            let content = UNMutableNotificationContent()
            content.body = body
            content.threadIdentifier = "ingest"
            // 银行短信本身已经响过，这条通知不再出声
            content.sound = nil
            let id = "ingest-\(result.ingestID ?? UUID().uuidString)-\(index)"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// 尾号 1234 卡，消费，¥128.00，记账成功
    /// 尾号 1234 卡，消费，128.00，记账失败：没有与尾号匹配的账户
    static func message(_ item: IngestItem, failuresOnly: Bool) -> String? {
        let succeeded: Bool
        var outcome: String
        switch item.result {
        case .recorded:
            succeeded = true
            outcome = "记账成功"
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

/// App 在前台时也显示记账结果通知的横幅。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
