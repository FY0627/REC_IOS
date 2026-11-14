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
/// 选「全部」时，还没分类、或者自动归类的流水可以长按选分类（ADR 0020）：每条通知用类别池子里的一个，类别上写好第一页按钮，
/// 长按时系统马上显示；通知扩展（`NotificationContent`）按 userInfo 里的 `NotificationPicker` 接着换按钮——翻页，点大类就地换成小类——
/// 点到一个分类把「pick.分类」交回这里，不打开 App，在后台保存（`handle`），锁屏时也能写
/// （账本的保护等级是 `completeUntilFirstUserAuthentication`，和自动化入账一样）。
/// 点「打开 App」或点通知本身，打开 App 里这一笔的选分类面板（`CategorizeRequest`）。
///
/// 有灵动岛的手机（ADR 0024）：选「全部」时，没分类的支出、收入改在灵动岛上选（`LiveCategoryActivity`），这一笔不发通知；
/// 没有灵动岛、关了实时活动、开启失败时照常发这条通知。
/// 摘要卡片（ADR 0027）：打开后改在快捷指令弹出的摘要卡片上选（`CategorySnippet`），由记账动作返回前弹；和灵动岛只开一个。
enum IngestNotifier {
    enum Mode: String, CaseIterable, Identifiable {
        case all
        case failures
        case off

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: L("全部")
            case .failures: L("仅失败")
            case .off: L("关闭（通知）")
            }
        }
    }

    static let modeKey = "notify.ingestResult"
    /// 有灵动岛的手机在岛上选分类（ADR 0024），默认开。「我的」里和摘要卡片只开一个
    static let islandKey = "notify.island"
    /// 在摘要卡片上选分类（ADR 0027），默认关
    static let snippetKey = "notify.snippet"

    static var islandOn: Bool { UserDefaults.standard.object(forKey: islandKey) as? Bool ?? true }
    static var snippetOn: Bool { UserDefaults.standard.bool(forKey: snippetKey) }

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

    /// `screenshot`：用户自己交的付款截图（ADR 0021）。和已有的一笔合并、认不出是付款页也说一声，敲了背面总要知道有没有记上。
    /// `snippets`：调用的是记账动作，能弹摘要卡片。打开了摘要卡片时，要在卡片上选的几笔不发通知，交回去由动作弹（`CategorySnippet.present`）
    @discardableResult
    static func post(_ result: IngestResult, backend: LedgerBackend, screenshot: Bool = false, snippets: Bool = false) async -> [CategorySnippet.Record] {
        let mode = mode
        guard mode != .off else { return [] }
        let center = UNUserNotificationCenter.current()
        if screenshot, result.items.isEmpty, mode == .all || result.outcome == .filtered {
            let content = UNMutableNotificationContent()
            content.body = result.outcome == .duplicateInput ? L("这张截图已经记过了") : L("截图里没有认出付款")
            content.threadIdentifier = "ingest"
            try? await center.add(UNNotificationRequest(identifier: "screenshot-\(UUID().uuidString)", content: content, trigger: nil))
            return []
        }
        var cards: [CategorySnippet.Record] = []
        for (index, item) in result.items.enumerated() {
            let suggestions = await categorySuggestions(for: item, backend: backend, screenshot: screenshot)
            let id = "ingest-\(result.ingestID ?? UUID().uuidString)-\(index)"
            if let recordID = item.recordID, LiveCategoryActivity.eligible(item, suggestions: suggestions) {
                // 摘要卡片（ADR 0027）：动作返回前一张一张弹，这一笔不发通知
                if snippets, snippetOn {
                    cards.append(CategorySnippet.Record(
                        recordID: recordID, header: header(item), suggestions: suggestions,
                        item: item, notificationID: id, screenshot: screenshot
                    ))
                    continue
                }
                // 有灵动岛时在岛上选分类（ADR 0024），这一笔不再发记账成功通知；没开成照常发
                if islandOn, await LiveCategoryActivity.show(recordID: recordID, suggestions: suggestions, header: header(item)) {
                    continue
                }
            }
            await send(item, id: id, suggestions: suggestions, mode: mode, screenshot: screenshot)
        }
        return cards
    }

    /// 一笔的记账结果通知。摘要卡片没弹出来时也走这里（`CategorySnippet.present`）
    static func send(_ item: IngestItem, id: String, suggestions: CategorySuggestions, mode: Mode? = nil, screenshot: Bool) async {
        let mode = mode ?? self.mode
        guard mode != .off else { return }
        guard let body = message(item, failuresOnly: mode == .failures, autoCategory: suggestions.autoCategory?.name.loc, screenshot: screenshot) else { return }
        let content = UNMutableNotificationContent()
        content.body = body
        content.threadIdentifier = "ingest"
        // 银行短信本身已经响过，这条通知不再出声
        content.sound = nil
        if let recordID = item.recordID, !suggestions.groups.isEmpty {
            // 分类名称和按钮上的字按选的语言写进去，通知扩展照着显示
            let picker = suggestions.picker.localized(name: \.loc, labels: pickerLabels)
            content.categoryIdentifier = await registerCategory(picker)
            content.userInfo = [recordIDKey: recordID, NotificationPicker.userInfoKey: picker.json]
            // 系统不让按钮露在收起的通知上，只能写一句告诉用户
            content.body += suggestions.autoCategory == nil ? L("，长按选分类") : L("，长按可改")
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: 通知上选分类

    /// 按钮上固定的字，按选的语言
    private static var pickerLabels: NotificationPicker.Labels {
        // 「只记%@」：插进去的就是「%@」，留给 `NotificationPicker` 换成大类名称
        NotificationPicker.Labels(only: L("只记\("%@")"), moreParents: L("更多大类"), back: L("返回"), more: L("更多"), openApp: L("打开 App"))
    }

    private static let recordIDKey = "recordID"
    /// 类别池子下一个轮到第几个
    private static let slotKey = "notify.pickSlot"

    /// 只有选「全部」时才有成功的通知，才带按钮
    /// 截图合并到银行那一笔时补上了商户，也可以接着选分类
    private static func categorySuggestions(for item: IngestItem, backend: LedgerBackend, screenshot: Bool) async -> CategorySuggestions {
        guard mode == .all, item.result == .recorded || (screenshot && item.result == .merged), let recordID = item.recordID else { return CategorySuggestions() }
        return (try? await backend.categorySuggestions(recordID: recordID)) ?? CategorySuggestions()
    }

    /// 从通知扩展认的类别池子（`NotificationPicker.categoryIDs`）里轮一个，写上这条通知的第一页按钮（ADR 0020）：
    /// 长按时系统马上显示，不用等扩展起来；扩展起来后设的还是这几个按钮，看不出变化，之后翻页、点大类换小类由扩展换。
    /// 池子轮着用，20 条以前的通知的按钮会被后来的换掉（扩展起来后会改回它自己的）。
    /// 注册是替换全部，所以留下池子里别的类别；没有完成回调：读回来看到了才发，一直看不到时照发
    private static func registerCategory(_ picker: NotificationPicker) async -> String {
        let ids = NotificationPicker.categoryIDs
        let action = { (button: NotificationPicker.Button) in Self.action(button, title: picker.title(button)) }
        let slot = UserDefaults.standard.integer(forKey: slotKey) % ids.count
        UserDefaults.standard.set(slot + 1, forKey: slotKey)
        let category = UNNotificationCategory(
            identifier: ids[slot], actions: picker.parentButtons(page: 0).map(action), intentIdentifiers: [], options: []
        )
        let center = UNUserNotificationCenter.current()
        for _ in 0..<5 {
            let registered = await center.notificationCategories()
            if registered.contains(where: { $0.identifier == category.identifier && $0.actions.map(\.identifier) == category.actions.map(\.identifier) }) {
                break
            }
            // 另一笔同时注册时可能盖掉了这一个，再补上
            center.setNotificationCategories(registered.filter { $0.identifier != category.identifier }.union([category]))
            try? await Task.sleep(for: .milliseconds(50))
        }
        return category.identifier
    }

    /// 和通知扩展里的按钮一样（`NotificationViewController.show`），改一边要改另一边。
    /// 选项不设 `.foreground` 就不打开 App，不设 `.authenticationRequired` 就不用解锁；「打开 App」要打开 App
    private static func action(_ button: NotificationPicker.Button, title: String) -> UNNotificationAction {
        UNNotificationAction(
            identifier: NotificationPicker.identifier(button), title: title,
            options: button == .app ? [.foreground] : [],
            icon: UNNotificationActionIcon(systemImageName: button.symbol)
        )
    }

    /// 通知扩展交回来的点击：系统在后台拉起 App 调到这里，写完才返回。
    /// 写不进去（开机后还没解锁过、流水或分类已经删了）时这笔留在原处，下次打开 App 再选。
    /// 点「打开 App」或通知本身：系统打开 App，这里只记下要打开哪一笔。
    /// 有小类的大类本来由扩展换成小类；扩展没起来、点击交到这里时，记到这个大类
    static func handle(_ response: UNNotificationResponse) async {
        guard let recordID = response.notification.request.content.userInfo[recordIDKey] as? String else { return }
        let identifier = response.actionIdentifier
        if identifier == NotificationPicker.appIdentifier || identifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { CategorizeRequest.shared.recordID = recordID }
            return
        }
        guard let prefix = [NotificationPicker.pickPrefix, NotificationPicker.openPrefix].first(where: { identifier.hasPrefix($0) }) else { return }
        let categoryID = String(identifier.dropFirst(prefix.count))
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
    /// 截图：微信零钱，示例便利店，消费，¥12.00，记账成功；和银行那笔合并时「…，和已记的一笔合并」
    static func message(_ item: IngestItem, failuresOnly: Bool, autoCategory: String? = nil, screenshot: Bool = false) -> String? {
        let succeeded: Bool
        var outcome: String
        switch item.result {
        case .recorded:
            succeeded = true
            outcome = L("记账成功")
            if let autoCategory { outcome += L("，已归到「\(autoCategory)」") }
        case .merged:
            guard screenshot else { return nil }
            succeeded = true
            outcome = L("和已记的一笔合并")
        case .pending(let reason):
            succeeded = false
            outcome = L("记账失败：\(reason.displayName.loc)，已放入待处理")
        }
        if failuresOnly, succeeded { return nil }
        if item.kind == nil, item.amountText == nil, item.amountMinor == nil {
            return screenshot ? L("截图没有认全，已放入待处理") : L("收到一条无法识别的银行通知，已放入待处理")
        }

        var parts: [String] = []
        parts.append(accountText(item))
        if screenshot, let counterparty = item.counterparty { parts.append(counterparty) }
        if let kind = item.kind {
            var action = kind.displayName.loc
            if let status = item.status, status != .posted { action = L("\(action)（\(status.displayName.loc)）") }
            parts.append(action)
        }
        if let amount = amountText(item) { parts.append(amount) }
        // 换成账户的另一个币种扣（ADR 0018）：「人民币余额不足，按港币扣约 HK$86.67」
        if let charge = item.charge, let currency = item.currency {
            let name = charge.currency.localizedName
            let charged = charge.amountMinor.map { minor in
                let money = Fmt.money(minor, charge.currency)
                return charge.isActual ? L("按\(name)扣 \(money)") : L("按\(name)扣约 \(money)")
            } ?? L("按\(name)扣（还没有汇率）")
            parts.append(item.insufficientBalance ? L("\(currency.localizedName)余额不足，\(charged)") : charged)
        }
        parts.append(outcome)
        return parts.joined(separator: L("，"))
    }

    /// 现金、电子钱包没有卡号：写账户名称
    private static func accountText(_ item: IngestItem) -> String {
        item.accountTitle?.loc ?? item.cardTail.map { L("尾号 \($0) 卡") } ?? L("未知尾号的卡")
    }

    /// 灵动岛、摘要卡片顶上一行：商户、账户、金额
    static func header(_ item: IngestItem) -> LiveCategoryActivity.Header {
        LiveCategoryActivity.Header(merchant: item.counterparty, account: accountText(item), amount: amountText(item) ?? "")
    }

    private static func amountText(_ item: IngestItem) -> String? {
        if let minor = item.amountMinor, let currency = item.currency {
            return Fmt.money(minor, currency)
        }
        guard let digits = item.amountText else { return nil }
        return item.currency.map { "\(digits) \($0.rawValue)" } ?? digits
    }
}

/// 点通知后要打开选分类面板的这一笔。App 可能正是被这次点击拉起来的，等账本打开后由 `RootView` 接手
@MainActor
@Observable
final class CategorizeRequest {
    static let shared = CategorizeRequest()

    var recordID: String?
}

/// 通知的代理：App 在前台时也显示记账结果通知的横幅；收到通知上的分类按钮。启动时设好（`AppDelegate`）。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// 要在主线程上收尾：异步版本默认在别的线程跑完，系统收尾时要求主线程，
    /// App 在前台时长按通知点分类按钮会崩溃（App 退出，重新打开回到首页）。写账本仍在数据库队列上
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await IngestNotifier.handle(response)
    }
}
