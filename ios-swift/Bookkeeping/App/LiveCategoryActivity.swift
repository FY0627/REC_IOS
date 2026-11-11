import ActivityKit
import Foundation
import BKBackend
import BKModel

/// 灵动岛选分类（ADR 0024）：自动记账记上一笔没分类的支出或收入后，开启一个实时活动，在岛上选分类，全程不打开 App。
///
/// - 只用在有灵动岛的手机（`DynamicIsland`，按机型）。没有灵动岛、系统里关了实时活动、开启失败时返回 false，照常发记账结果通知（长按选分类，ADR 0020）；
/// - 两个记账动作遵循 `LiveActivityIntent`，在它们的 perform 里开启：系统只让用户经快捷指令、Siri、小组件运行的动作从后台开启；
/// - 开启后马上发一次会提醒的更新，让岛自动展开、锁屏亮屏。不出声：银行短信已经响过，和记账结果通知一样；
/// - 只留一个：又记了一笔要选的，就换成这一笔，原来那一笔排着（`LiveCategoryQueue`）；
/// - 不设时长：用户不选就留着，自己上滑收起；系统最长 8 小时后结束。这一笔在 App 里选了分类、删了，打开或离开 App 时换下一笔（`reconcile`）。
///
/// 岛上的按钮（`PickLiveCategoryIntent`、`ShowLiveCategoryPageIntent`）在 App 进程里运行到这里：
/// 换页只读开启时存下的选项（`LiveCategoryPicker`），不开账本；点到分类时写进账本，显示选中的分类一下，
/// 再换成排着的下一笔（还没分类的），没有了才结束
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
    /// 「开发与调试」里显示上次点岛上的按钮 App 这边花了多久（系统叫起 App、重画岛的时间不在里面）
    static let lastTapKey = "liveCategory.lastTap"
    /// 这次 App 启动的时候（`AppDelegate` 启动时先取一次）：按钮把 App 拉起来时，记下启动后多久才轮到按钮的动作
    static let launchedAt = ContinuousClock.now
    private static let pickerKey = "liveCategory.picker"
    private static let pickerRecordKey = "liveCategory.pickerRecord"
    private static let queueKey = "liveCategory.queue"
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

    /// 在岛上选这一笔的分类：已经有一个就换成这一笔（原来没选的那一笔排着），然后发一次会提醒的更新。
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
        let record = LiveCategoryQueue.Entry(recordID: recordID, merchant: header.merchant, account: header.account, amount: header.amount)
        let content = ActivityContent(state: makeState(record, picker: picker), staleDate: nil)
        let alert = makeAlert(record)
        let current = running()
        var queue = loadQueue()
        if let showing = current.first?.content.state {
            // 岛上那一笔已经选好（正在显示选中的分类）就不用排
            if showing.chosen == nil, showing.recordID != recordID { queue.wait(queueEntry(showing)) }
        } else {
            // 岛被上滑收起了：之前排着的不再接着弹，留在待分类
            queue = LiveCategoryQueue()
        }
        queue.remove(recordID)
        saveQueue(queue)
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
        let started = ContinuousClock.now
        guard let page = LiveCategoryPicker.Page(token: token), let activity = find(recordID),
              let picker = await loadPicker(recordID) else { return }
        var state = activity.content.state
        state.screen = picker.screen(page)
        await activity.update(ActivityContent(state: state, staleDate: nil))
        noteTap([L("换页 \(milliseconds(since: started)) ms")], started: started)
    }

    /// 点到一个分类：先在岛上显示选中的分类，再写进账本（学习和通知上选分类一样）——等写完再显示，点了要多等一会。
    /// 显示约 1 秒后换成排着的下一笔；没有了就结束、马上消失。
    /// 写不进去（开机后还没解锁过）时岛换回按钮，可以再点或单点打开 App；这一笔已经删了就直接换下一笔
    @MainActor
    static func pick(recordID: String, categoryID: String) async {
        let started = ContinuousClock.now
        let activity = find(recordID)
        var shown: ActivityContent<State>?
        var shownAt = started
        if let activity {
            var state = activity.content.state
            state.chosen = await loadPicker(recordID)?.option(categoryID) ?? LiveCategoryPicker.Option(id: categoryID, name: "", symbol: "checkmark")
            let chosen = ActivityContent(state: state, staleDate: nil)
            await activity.update(chosen)
            shown = chosen
            shownAt = .now
        }
        let shownTime = milliseconds(since: started)
        guard let backend = await openBackend() else {
            await undoChosen(activity, recordID: recordID)
            note(L("写入失败"))
            return
        }
        do {
            try await backend.setCategory(recordID: recordID, categoryID: categoryID)
        } catch BackendError.notFound {
            if let activity { await advance(activity, from: recordID, backend: backend, alert: true) }
            return
        } catch {
            AppServices.logger.error("live activity pick failed: \(String(describing: type(of: error)), privacy: .public)")
            await undoChosen(activity, recordID: recordID)
            note(L("写入失败"))
            return
        }
        noteTap([L("选分类：显示 \(shownTime) ms，写账本 \(milliseconds(since: started)) ms")], started: started)
        NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        guard let activity, let shown else { return }
        try? await Task.sleep(until: shownAt + chosenDisplay, clock: .continuous)
        // 这期间来了新的一笔、岛已经换成它了，就不动
        guard activity.content.state.recordID == recordID else { return }
        await advance(activity, from: recordID, backend: backend, final: shown, alert: true)
    }

    /// 写不进账本：岛上换回这一笔的按钮
    @MainActor
    private static func undoChosen(_ activity: Activity<CategoryActivityAttributes>?, recordID: String) async {
        guard let activity, activity.content.state.recordID == recordID else { return }
        var state = activity.content.state
        state.chosen = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    // MARK: 打开、离开 App

    /// 岛上这一笔已经在 App 里选了分类或者删了：换成排着的下一笔，没有了就结束
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
            await advance(activity, from: recordID, backend: backend, alert: false)
        }
    }

    // MARK: 下一笔

    /// 岛上这一笔选好了（或者在 App 里选了、删了）：换成排着的最近一笔，跳过已经分好类、删了的；没有了就结束。
    /// `alert`：在岛上点的，岛可能已经收起来了，提醒一下让它再展开；在 App 里选的不用
    @MainActor
    private static func advance(
        _ activity: Activity<CategoryActivityAttributes>, from recordID: String, backend: LedgerBackend,
        final: ActivityContent<State>? = nil, alert: Bool
    ) async {
        clearStored(recordID)
        var queue = loadQueue()
        queue.remove(recordID)
        while let next = queue.next() {
            guard let suggestions = await waitingSuggestions(next.recordID, backend: backend) else { continue }
            saveQueue(queue)
            let picker = makePicker(suggestions)
            store(picker, recordID: next.recordID)
            let content = ActivityContent(state: makeState(next, picker: picker), staleDate: nil)
            if alert {
                await activity.update(content, alertConfiguration: makeAlert(next))
            } else {
                await activity.update(content)
            }
            return
        }
        saveQueue(queue)
        await activity.end(final, dismissalPolicy: .immediate)
    }

    /// 排着的这一笔还要选：还在、还没分类、有分类可选
    private static func waitingSuggestions(_ recordID: String, backend: LedgerBackend) async -> CategorySuggestions? {
        guard let detail = try? await backend.recordDetail(id: recordID), detail.row.record.categoryID == nil,
              let suggestions = try? await backend.categorySuggestions(recordID: recordID), !suggestions.groups.isEmpty
        else { return nil }
        return suggestions
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

    /// 第 1 页，主题色按现在 App 里选的
    private static func makeState(_ record: LiveCategoryQueue.Entry, picker: LiveCategoryPicker) -> State {
        State(
            recordID: record.recordID, merchant: record.merchant, account: record.account, amount: record.amount,
            screen: picker.screen(.quick), chosen: nil,
            tint: UserDefaults.standard.string(forKey: ThemeColor.key) ?? ThemeColor.blue.rawValue
        )
    }

    private static func queueEntry(_ state: State) -> LiveCategoryQueue.Entry {
        LiveCategoryQueue.Entry(recordID: state.recordID, merchant: state.merchant, account: state.account, amount: state.amount)
    }

    /// 岛自动展开、锁屏亮屏，不出声
    private static func makeAlert(_ record: LiveCategoryQueue.Entry) -> AlertConfiguration {
        AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: record.merchant ?? record.account),
            body: LocalizedStringResource(stringLiteral: record.amount),
            sound: .named(silentSound)
        )
    }

    private static func loadQueue() -> LiveCategoryQueue {
        UserDefaults.standard.string(forKey: queueKey).flatMap(LiveCategoryQueue.init(json:)) ?? LiveCategoryQueue()
    }

    private static func saveQueue(_ queue: LiveCategoryQueue) {
        if queue.waiting.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
        } else {
            UserDefaults.standard.set(queue.json, forKey: queueKey)
        }
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

    /// App 刚被这次点击拉起来（启动不到 3 秒）时，再写上启动后多久才轮到按钮的动作
    @MainActor
    private static func noteTap(_ parts: [String], started: ContinuousClock.Instant) {
        var parts = parts
        let sinceLaunch = started - launchedAt
        if sinceLaunch < .seconds(3) { parts.append(L("启动后 \(milliseconds(sinceLaunch)) ms")) }
        UserDefaults.standard.set("\(Fmt.dateTime(Date())) \(parts.joined(separator: " · "))", forKey: lastTapKey)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        milliseconds(.now - start)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
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
