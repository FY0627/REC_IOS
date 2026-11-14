import ActivityKit
import Foundation
import UIKit
import BKBackend
import BKModel

/// 灵动岛选分类（ADR 0024）：自动记账记上一笔没分类的支出或收入后，开启一个实时活动，在岛上选分类，全程不打开 App。
///
/// - 有灵动岛的手机（`DynamicIsland`，按机型）在岛上选；
/// - 没有灵动岛的手机只放提醒（`ContentState.reminderOnly`）：锁屏卡片是提醒，记上一笔时发一次带提醒的更新，
///   系统把这张卡片当横幅在屏幕上方弹一下（苹果文档：没有灵动岛时，只有带 `AlertConfiguration` 的更新才弹横幅）；不放按钮，单点打开 App 这一笔；
/// - 系统里关了实时活动、开启失败时返回 false，照常发记账结果通知（长按选分类，ADR 0020）；
/// - 两个记账动作遵循 `LiveActivityIntent`，在它们的 perform 里开启：系统只让用户经快捷指令、Siri、小组件运行的动作从后台开启；
/// - 不发会提醒的更新：那样岛会自己展开，几秒后不管有没有在点都会收回。长按展开再选；
/// - 但 App 不在前台时新开启的，系统有时还是先展开几秒再收回，没有接口关掉、也留不住，也没有公开是几秒。
///   所以新开启的岛先是一张提醒（`ContentState.notice`：照 AirPods 连上时的样子，「刚刚记了一笔 / 待分类」和待分类的笔数，
///   不放商户、金额），单点打开 App 这一笔的选分类面板；
///   `openingTime`（「开发与调试」里调）后 App 自己更新一次换成按钮，之后长按展开就能在岛上选。
///   App 是在后台被拉起来的，要一段后台时间撑到那时；没撑到的，打开或离开 App 时换（`reconcile`）；
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
    /// 选好以后后面几步什么时候开始（从第一步放出来算，`ChosenStep`）。用户的录屏量的：淡出约 0.35 秒，岛变矮约 0.45 秒，对勾画约 0.2 秒
    private static let chosenSteps: [(CategoryActivityAttributes.ChosenStep, Duration)] = [
        (.sizing, .milliseconds(400)), (.showing, .milliseconds(950)), (.checked, .milliseconds(1400)),
    ]
    /// 什么时候往上走掉：对勾画完再停一会儿
    private static let chosenDisplay: Duration = .milliseconds(2300)
    /// 没有下一笔：整页往上走掉以后再结束。实时活动的动画用系统自己的时长（ActivityKit 文档：忽略 `animation` 修饰符），
    /// 0.35 秒就结束，往上走还没走完岛就收了；留 0.6 秒
    private static let leaveTime: Duration = .milliseconds(600)
    /// 没有灵动岛时提醒横幅的声音：一段没有声音的文件（提醒必须带声音；短信、推送本身已经响过，截图是自己敲的）
    private static let silentSound = "Silence.wav"
    /// 新开启的岛先放提醒多久，再换成按钮：系统自己展开几秒没有公开的数字，用户在真机上量的是 3 秒，试过 3 秒刚好
    private static let openingTime: TimeInterval = 3
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

    /// 在岛上选这一笔的分类：已经有一个就换成这一笔（原来没选的那一笔排着）。
    /// 不发会提醒的更新：那样岛会自己展开，几秒后不管有没有在点都会收回。岛收着（左边图标、右边金额），长按展开再选；
    /// 新开启的系统有时先展开几秒：这时展开的是提醒，还有几笔待分类。成功返回 true，这一笔不再发记账成功通知
    @MainActor
    static func show(recordID: String, suggestions: CategorySuggestions, header: Header) async -> Bool {
        let island = DynamicIsland.isPresent(model: modelIdentifier)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            note(L("实时活动已关闭"))
            return false
        }
        let picker = makePicker(suggestions)
        store(picker, recordID: recordID)
        let record = LiveCategoryQueue.Entry(recordID: recordID, merchant: header.merchant, account: header.account, amount: header.amount)
        var state = makeState(record, picker: picker)
        // 刚开启或者还在刚开启那几秒里换成这一笔：系统可能正展开着，放提醒（`present` 过了时间会去掉）。
        // 没有灵动岛的一直是提醒
        state.notice = await makeNotice()
        state.reminderOnly = island ? nil : true
        let content = ActivityContent(state: state, staleDate: nil)
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
            if island {
                await present(activity, content.state)
            } else {
                await announce(activity, content.state)
            }
            for extra in current.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            note(L("实时活动已更新"))
            return true
        }
        do {
            let activity = try Activity.request(
                attributes: CategoryActivityAttributes(),
                content: ActivityContent(state: content.state, staleDate: island ? Date(timeIntervalSinceNow: openingTime) : nil),
                pushType: nil
            )
            if island {
                fillButtonsLater(activity)
            } else {
                await announce(activity, content.state)
            }
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
        // 点的是左上角的返回：往回滚
        state.back = state.screen.back == page
        state.screen = picker.screen(page)
        await present(activity, state)
        noteTap([L("换页 \(milliseconds(since: started)) ms")], started: started)
    }

    /// 点到一个分类：岛上一步一步换成选好的样子（`ChosenStep`，一步一次更新，每步等上一步的动画放完）：
    /// 商户、金额和按钮淡出 → 岛矮回提醒的高度 → 选好的样子从下往上出来 → 对勾画出来 → 往上走掉，再结束或换成排着的下一笔。
    /// 第一步放出来就写进账本（学习和通知上选分类一样），不等写完再显示，点了不用多等。
    /// 写不进去（开机后还没解锁过）时岛换回按钮，可以再点或单点打开 App；这一笔已经删了就直接换下一笔
    @MainActor
    static func pick(recordID: String, categoryID: String) async {
        let started = ContinuousClock.now
        let activity = find(recordID)
        var shownAt = started
        if let activity {
            var state = activity.content.state
            state.chosen = await loadPicker(recordID)?.option(categoryID) ?? LiveCategoryPicker.Option(id: categoryID, name: "", symbol: "checkmark")
            state.chosenCaption = L("已分类")
            state.back = false
            state.chosenStep = .clearing
            await present(activity, state)
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
            if let activity { await advance(activity, from: recordID, backend: backend) }
            return
        } catch {
            AppServices.logger.error("live activity pick failed: \(String(describing: type(of: error)), privacy: .public)")
            await undoChosen(activity, recordID: recordID)
            note(L("写入失败"))
            return
        }
        noteTap([L("选分类：显示 \(shownTime) ms，写账本 \(milliseconds(since: started)) ms")], started: started)
        NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        guard let activity else { return }
        // 后面几步到点再走。这期间来了新的一笔、岛已经换成它了，就不动
        for (step, time) in chosenSteps {
            try? await Task.sleep(until: shownAt + time, clock: .continuous)
            guard activity.content.state.recordID == recordID, activity.content.state.chosen != nil else { return }
            var next = activity.content.state
            next.chosenStep = step
            await present(activity, next)
        }
        try? await Task.sleep(until: shownAt + chosenDisplay, clock: .continuous)
        guard activity.content.state.recordID == recordID else { return }
        await advance(activity, from: recordID, backend: backend, leave: true)
    }

    /// 写不进账本：岛上换回这一笔的按钮
    @MainActor
    private static func undoChosen(_ activity: Activity<CategoryActivityAttributes>?, recordID: String) async {
        guard let activity, activity.content.state.recordID == recordID else { return }
        var state = activity.content.state
        state.chosen = nil
        state.chosenStep = nil
        state.back = true
        await present(activity, state)
    }

    /// 换岛上的内容。旧内容按它自己身上的方向滚走（`IslandMotion`），所以这次和上次方向不一样时，
    /// 先只改方向更新一次（看不出变化），再换内容。
    /// 还在刚开启那几秒里（系统可能还展开着）：换了内容也还是提醒，到原来的时间再换成按钮；过了时间不再有提醒
    @MainActor
    private static func present(_ activity: Activity<CategoryActivityAttributes>, _ state: State) async {
        let showing = activity.content
        let openingUntil = openingDeadline(showing)
        var state = state
        if showing.state.isReminderOnly {
            // 没有灵动岛：一直是提醒
            state.reminderOnly = true
            state.notice = state.notice ?? showing.state.notice
        } else {
            state.notice = openingUntil == nil ? nil : (state.notice ?? showing.state.notice)
        }
        if showing.state.isBack != state.isBack {
            var turned = showing.state
            turned.back = state.back
            turned.notice = state.notice
            await activity.update(ActivityContent(state: turned, staleDate: openingUntil))
        }
        await activity.update(ActivityContent(state: state, staleDate: openingUntil))
    }

    /// 没有灵动岛：换成这一笔的提醒，发一次带提醒的更新，锁屏卡片当横幅弹一下（不出声）。手表上显示 title 和 body
    @MainActor
    private static func announce(_ activity: Activity<CategoryActivityAttributes>, _ state: State) async {
        let notice = state.notice ?? CategoryActivityAttributes.Notice(caption: L("刚刚记了一笔"), title: L("待分类"), count: 1)
        let alert = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: notice.caption),
            body: LocalizedStringResource(stringLiteral: notice.title),
            sound: .named(silentSound)
        )
        await activity.update(ActivityContent(state: state, staleDate: nil), alertConfiguration: alert)
    }

    /// 还在刚开启那几秒里：换成按钮的时间（开启时写在 `staleDate` 上）；已经过了、不是刚开启的是 nil
    private static func openingDeadline(_ content: ActivityContent<State>) -> Date? {
        guard content.state.isOpening, let until = content.staleDate, until > Date() else { return nil }
        return until
    }

    /// 刚开启的岛到 `openingTime` 换成按钮：不提醒、不展开。
    /// App 是被快捷指令在后台拉起来的，动作返回后很快会被挂起，所以先要一段后台时间撑到那时
    @MainActor
    private static func fillButtonsLater(_ activity: Activity<CategoryActivityAttributes>) {
        let time = BackgroundTime(name: "liveCategory.opening")
        let wait = openingTime
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            await fillButtons(activity)
            time.end()
        }
    }

    /// 还是提醒就换成按钮。这期间换成了别的一笔也一样换（换的时候留着提醒）
    @MainActor
    private static func fillButtons(_ activity: Activity<CategoryActivityAttributes>) async {
        guard activity.activityState == .active || activity.activityState == .stale, activity.content.state.isOpening,
              !activity.content.state.isReminderOnly else { return }
        var state = activity.content.state
        state.notice = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// 刚开启的提醒：「刚刚记了一笔」「待分类」，圆环里是账本里没分类的支出、收入的笔数，算上这一笔；读不出来时写 1
    private static func makeNotice() async -> CategoryActivityAttributes.Notice {
        var count = 1
        if let backend = await openBackend(), let total = try? await backend.uncategorizedCount() { count = max(total, 1) }
        return CategoryActivityAttributes.Notice(caption: L("刚刚记了一笔"), title: L("待分类"), count: count)
    }

    // MARK: 打开、离开 App

    /// 岛上这一笔已经在 App 里选了分类或者删了：换成排着的下一笔，没有了就结束。
    /// 刚开启的岛过了时间还是提醒（App 没撑到就被挂起了）：现在换成按钮
    @MainActor
    static func reconcile() async {
        for activity in running() where activity.content.state.isOpening && openingDeadline(activity.content) == nil {
            await fillButtons(activity)
        }
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
            await advance(activity, from: recordID, backend: backend)
        }
    }

    /// 换账本（演示数据开关，ADR 0025）：岛上和排着的都是另一个账本的，全部结束、清掉
    @MainActor
    static func endAll() async {
        for activity in running() { await activity.end(nil, dismissalPolicy: .immediate) }
        let defaults = UserDefaults.standard
        for key in [queueKey, pickerKey, pickerRecordKey] { defaults.removeObject(forKey: key) }
    }

    // MARK: 下一笔

    /// 岛上这一笔选好了（或者在 App 里选了、删了）：换成排着的最近一笔，跳过已经分好类、删了的；没有了就结束。
    /// 在同一个岛上接着换内容，不提醒：展开着就还展开着，收着就还收着。
    /// `leave`：在岛上选好的，选好的样子先往上走掉，再结束（和岛收回去的方向一样）或换下一笔
    @MainActor
    private static func advance(
        _ activity: Activity<CategoryActivityAttributes>, from recordID: String, backend: LedgerBackend,
        leave: Bool = false
    ) async {
        clearStored(recordID)
        var queue = loadQueue()
        queue.remove(recordID)
        var upcoming: State?
        while let next = queue.next() {
            guard let suggestions = await waitingSuggestions(next.recordID, backend: backend) else { continue }
            let picker = makePicker(suggestions)
            store(picker, recordID: next.recordID)
            var state = makeState(next, picker: picker)
            // 没有灵动岛：提醒里的笔数跟着变
            if activity.content.state.isReminderOnly { state.notice = await makeNotice() }
            upcoming = state
            break
        }
        saveQueue(queue)
        if leave {
            var leaving = activity.content.state
            leaving.chosenStep = .leaving
            await present(activity, leaving)
            try? await Task.sleep(for: leaveTime)
        }
        if let upcoming {
            await present(activity, upcoming)
            return
        }
        await activity.end(leave ? ActivityContent(state: activity.content.state, staleDate: nil) : nil, dismissalPolicy: .immediate)
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

/// 一段后台时间：App 在后台被拉起来、动作已经返回，还要等几秒再更新岛。用完或系统收回时结束
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
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
