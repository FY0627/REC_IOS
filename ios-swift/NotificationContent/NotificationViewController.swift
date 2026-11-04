import UIKit
import UserNotifications
import UserNotificationsUI
import BKModel

/// 记账结果通知长按后的选分类（ADR 0020）：按钮先是大类，「更多大类」翻页；点有小类的大类，按钮当场换成它的小类；
/// 点到一个分类就把「pick.分类」交回 App 保存（`IngestNotifier.handle`），不用再等第二条通知。
/// 扩展不读账本：大类、小类和顺序是 App 发通知时写进 userInfo 的（`NotificationPicker`）。
/// 自己不画内容，只用系统的标题和正文
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var picker = NotificationPicker(first: nil, groups: [])

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: view.bounds.width, height: 1)
    }

    func didReceive(_ notification: UNNotification) {
        let json = notification.request.content.userInfo[NotificationPicker.userInfoKey] as? String
        picker = json.flatMap(NotificationPicker.init(json:)) ?? NotificationPicker(first: nil, groups: [])
        show(picker.parentButtons(page: 0))
    }

    func didReceive(_ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        if let buttons = picker.buttons(after: response.actionIdentifier) {
            show(buttons)
            completion(.doNotDismiss)
        } else {
            // 选好了分类、打开 App：交给 App
            completion(.dismissAndForwardAction)
        }
    }

    private func show(_ buttons: [NotificationPicker.Button]) {
        extensionContext?.notificationActions = buttons.map { button in
            UNNotificationAction(
                identifier: NotificationPicker.identifier(button), title: button.title,
                options: button == .app ? [.foreground] : [],
                icon: UNNotificationActionIcon(systemImageName: button.symbol)
            )
        }
    }
}
