import ActivityKit
import Foundation
import BKBackend
import BKModel

/// 灵动岛选分类（ADR 0024）：自动记账记上一笔没分类的支出或收入后，开启一个实时活动，在岛上选分类，全程不打开 App。
///
/// - 只用在有灵动岛的手机（`DynamicIsland`，按机型）。没有灵动岛、系统里关了实时活动、开启失败时返回 false，照常发记账结果通知（长按选分类，ADR 0020）；
/// - 两个记账动作遵循 `LiveActivityIntent`，在它们的 perform 里开启：系统只让用户经快捷指令、Siri、小组件运行的动作从后台开启；
/// - 开启后马上发一次会提醒的更新，让岛自动展开、锁屏亮屏。不出声：银行短信已经响过，和记账结果通知一样；
/// - 只留一个：又记了一笔要选的，就换成这一笔；
/// - 不设时长：用户不选就留着，自己上滑收起；系统最长 8 小时后结束。这一笔在 App 里选了分类、删了，打开或离开 App 时结束（`reconcile`）。
///
/// 岛上的按钮（`PickLiveCategoryIntent`、`ShowLiveCategoryPageIntent`）在 App 进程里运行到这里：
/// 换页只读开启时存下的选项（`LiveCategoryPicker`），不开账本；点到分类时写进账本，显示选中的分类一下再结束
enum LiveCategoryActivity {
    typealias State = CategoryActivityAttributes.ContentState

    /// 岛上顶上一行：商户、账户、金额
    struct Header: Sendable {
        var merchant: String?
        var account: String
        var amount: String
    }

    /// 「开发与调试」里显示上次开启的结果，装到手机上看后台能不能开启
    static let lastResultKey = "liveCategory.lastResult"
    private static let pickerKey = "liveCategory.picker"
    private static let pickerRecordKey = "liveCategory.pickerRecord"
    /// 选好的分类在岛上显示多久再结束
    private static let chosenDisplay: Duration = .milliseconds(1200)
    /// 提醒更新的声音：一段没有声音的文件（系统要求提醒带声音）
    private static let silentSound = "Silence.wav"
    /// 转帐、退款不弹：转帐不用分类，退款跟着原交易；没确认对方的转账选了分类就是转给别人
    private static let skippedKinds: Set<TransactionKind> = [.transferIn, .transferOut, .refund, .reversal]

    /// 这一笔要在岛上选：入账成功（截图合并到的也算，`IngestNotifier` 先筛过）、还没分类、不是转帐退款
    static func eligible(_ item: IngestItem, suggestions: CategorySuggestions) -> Bool {
        guard item.recordID != nil, suggestions.autoCategory == nil, !suggestions.groups.isEmpty else { return false }
        return !(item.kind.map { skippedKinds.contains($0) } ?? false)
    }

    /// 机型标识符，例如 `iPhone15,2`；模拟器上是它模拟的机型
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: 开启

    /// 在岛上选这一笔的分类：已经有一个就换成这一笔，然后发一次会提醒的更新。
    /// 成功返回 true，这一笔不再发记账成功通知
    @MainActor
    static func show(recordID: String, suggestions: CategorySuggestions, header: Header) async -> Bool {
        guard DynamicIsland.isPresent(model: modelIdentifier) else { return false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            note(L("实时活动已关闭"))
            return false
        }
        let picker = makePicker(suggestions)
        store(picker, recordID: recordID)
        let state = State(
            recordID: recordID, merchant: header.merchant, account: header.account, amount: header.amount,
            screen: picker.screen(.quick), chosen: nil,
            tint: UserDefaults.standard.string(forKey: ThemeColor.key) ?? ThemeColor.blue.rawValue
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let alert = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: header.merchant ?? header.account),
            body: LocalizedStringResource(stringLiteral: header.amount),
            sound: .named(silentSound)
        )
        let current = running()
        if let activity = current.first {
            await activity.update(content, alertConfiguration: alert)
            for extra in current.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            note(L("实时活动已更新"))
            return true
        }
        do {
            let activity = try Activity.request(attributes: CategoryActivityAttributes(), content: content, pushType: nil)
            await activity.update(content, alertConfiguration: alert)
            note(L("实时活动已开启"))
            return true
        } catch {
            AppServices.logger.error("live activity request failed: \(String(describing: error), privacy: .public)")
            note(L("开启失败：\(String(describing: error))"))
            return false
        }
    }

    // MARK: 岛上的按钮

    /// 「全部」「更多」「返回」、有小类的大类：换一页
    @MainActor
    static func turn(recordID: String, to token: String) async {
        guard let page = LiveCategoryPicker.Page(token: token), let activity = find(recordID),
              let picker = await loadPicker(recordID) else { return }
        var state = activity.content.state
        state.screen = picker.screen(page)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// 点到一个分类：写进账本（学习和通知上选分类一样），岛上显示选中的分类一下，然后结束、马上消失。
    /// 写不进去（开机后还没解锁过）时岛留着，可以再点或单点打开 App；这一笔已经删了就结束
    @MainActor
    static func pick(recordID: String, categoryID: String) async {
        guard let backend = await openBackend() else {
            note(L("写入失败"))
            return
        }
        do {
            try await backend.setCategory(recordID: recordID, categoryID: categoryID)
        } catch BackendError.notFound {
            await end(recordID)
            return
        } catch {
            AppServices.logger.error("live activity pick failed: \(String(describing: type(of: error)), privacy: .public)")
            note(L("写入失败"))
            return
        }
        NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        guard let activity = find(recordID) else { return }
        var state = activity.content.state
        state.chosen = await loadPicker(recordID)?.option(categoryID) ?? LiveCategoryPicker.Option(id: categoryID, name: "", symbol: "checkmark")
        await activity.update(ActivityContent(state: state, staleDate: nil))
        try? await Task.sleep(for: chosenDisplay)
        // 这期间换成了下一笔就不结束
        guard activity.content.state.recordID == recordID else { return }
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        clearStored(recordID)
    }

    // MARK: 打开、离开 App

    /// 岛上这一笔已经在 App 里选了分类或者删了：结束
    @MainActor
    static func reconcile() async {
        let current = running().filter { $0.content.state.chosen == nil }
        guard !current.isEmpty, let backend = await openBackend() else { return }
        for activity in current {
            let recordID = activity.content.state.recordID
            do {
                guard try await backend.recordDetail(id: recordID).row.record.categoryID != nil else { continue }
            } catch BackendError.notFound {
                // 删了
            } catch {
                continue
            }
            await end(recordID)
        }
    }

    // MARK: 内部

    @MainActor
    private static func running() -> [Activity<CategoryActivityAttributes>] {
        Activity<CategoryActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    @MainActor
    private static func find(_ recordID: String) -> Activity<CategoryActivityAttributes>? {
        running().first { $0.content.state.recordID == recordID }
    }

    @MainActor
    private static func end(_ recordID: String) async {
        await find(recordID)?.end(nil, dismissalPolicy: .immediate)
        clearStored(recordID)
    }

    /// 分类名称和固定的字按 App 里选的语言写好，扩展照着显示
    private static func makePicker(_ suggestions: CategorySuggestions) -> LiveCategoryPicker {
        let type = suggestions.groups.first?.parent.type ?? .expense
        // 「只记%@」：插进去的就是「%@」，留给 `LiveCategoryPicker` 换成大类名称
        let labels = LiveCategoryPicker.Labels(all: L("全部"), more: L("更多"), only: L("只记\("%@")"), type: type.displayName.loc)
        return LiveCategoryPicker(suggestions).localized(name: \.loc, labels: labels)
    }

    /// 开启时存下的选项；存的不是这一笔（刚换成了下一笔）时从账本重新算
    @MainActor
    private static func loadPicker(_ recordID: String) async -> LiveCategoryPicker? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: pickerRecordKey) == recordID, let json = defaults.string(forKey: pickerKey),
           let picker = LiveCategoryPicker(json: json) {
            return picker
        }
        guard let backend = await openBackend(), let suggestions = try? await backend.categorySuggestions(recordID: recordID),
              !suggestions.groups.isEmpty else { return nil }
        let picker = makePicker(suggestions)
        store(picker, recordID: recordID)
        return picker
    }

    private static func store(_ picker: LiveCategoryPicker, recordID: String) {
        UserDefaults.standard.set(picker.json, forKey: pickerKey)
        UserDefaults.standard.set(recordID, forKey: pickerRecordKey)
    }

    private static func clearStored(_ recordID: String) {
        guard UserDefaults.standard.string(forKey: pickerRecordKey) == recordID else { return }
        UserDefaults.standard.removeObject(forKey: pickerKey)
        UserDefaults.standard.removeObject(forKey: pickerRecordKey)
    }

    /// App 可能是被岛上的按钮拉起来的：打开账本（含迁移）放在后台线程
    private static func openBackend() async -> LedgerBackend? {
        try? await Task.detached(priority: .userInitiated) { try AppServices.shared.backend() }.value
    }

    @MainActor
    private static func note(_ text: String) {
        UserDefaults.standard.set("\(Fmt.dateTime(Date())) \(text)", forKey: lastResultKey)
    }
}

/// 岛上按钮的动作（`Shared/CategoryActivity.swift`）在 App 进程里运行到这里。扩展里有一份同名的空壳
enum LiveCategoryActions {
    static func pick(recordID: String, categoryID: String) async {
        await LiveCategoryActivity.pick(recordID: recordID, categoryID: categoryID)
    }

    static func show(recordID: String, page: String) async {
        await LiveCategoryActivity.turn(recordID: recordID, to: page)
    }
}
