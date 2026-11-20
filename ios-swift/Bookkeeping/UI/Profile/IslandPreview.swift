import SwiftUI
import UIKit
import BKModel

/// 「我的 › 通知 › 灵动岛」打开时下面的演示（ADR 0024）：一个能点的岛，没有底色，自己浮在设置项下面。
///
/// 和真的岛一样走一遍，动起来也照真的岛（`IslandMotion`）：
/// 1. 只有摄像头 → 岛弹开成提醒：左边收据图标，中间「刚刚记了一笔 / 待分类」，右边圆环里是还有几笔没分类；
/// 2. 3 秒后（真的岛也是 3 秒，`openingTime`）收成小岛，摄像头左边一个标签图标、右边没有东西。长按展开成按钮，不长按就一直收着；
/// 3. 按钮三页：第 1 页 4 个推荐和「全部」，「全部」是全部大类，点有小类的大类进小类，左上角返回。
///    换页整页上下滚：往里点旧的往上走、新的从下面上来，返回反过来。
///    分类是账本里自己的支出分类，页怎么分、按钮点了去哪用的就是岛上那一套（`LiveCategoryPicker`）；
/// 4. 点到分类：按钮淡出，选好的一行从下面上来（分类图标、「已分类」和分类名），右边的圆圈从 12 点画一圈、再画出对勾；
///    停一下，还有下一笔就整页滚到下一笔的按钮，没有了岛收回只剩摄像头；
/// 5. 一轮选完从头再来。一轮 1 笔、下一轮 2 笔，这样交替，一笔和连着几笔的样子都看得到。不记账。
/// 选「仅提醒」时没有按钮：小岛长按展开的还是提醒（真的岛上单点打开 App 选），看一会儿收回，下一轮。
///
/// 尺寸照 `CategoryActivity` 里的 `IslandLayout`：按钮的岛宽 371、高 10 + 32 + 8 + 92 + 16 = 158，提醒的岛约 95，小岛 37 高。
/// 按真的尺寸画好再整体缩到这一行的宽度，元素之间的比例和真机一样；这一行一直留着 158 高，岛变大变小时下面的东西不跳。
/// 系统设置里减弱动态效果时不做动画。没有灵动岛的手机画待分类的提醒横幅（`ReminderCard`），不能点。
/// 岛是黑色的；深色模式下页面也是黑的，岛换成深灰，跟着外观实时换
struct IslandPreview: View {
    let hasIsland: Bool
    /// 「仅提醒」：小岛长按展开的还是提醒，没有按钮
    let reminderOnly: Bool

    @Environment(LedgerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue
    @State private var demo: IslandDemo
    @State private var step = IslandDemo.Step.tapped
    /// 换页往回走（返回）：整页从上面下来
    @State private var backward = false
    /// 长按展开的次数：每次震一下
    @State private var presses = 0

    private var tint: Color { ThemeColor.color(stored: themeColor) }
    private var size: CGSize { hasIsland ? IslandShape.island : IslandShape.reminder }

    init(hasIsland: Bool, reminderOnly: Bool) {
        self.hasIsland = hasIsland
        self.reminderOnly = reminderOnly
        _demo = State(initialValue: IslandDemo(reminderOnly: reminderOnly))
    }

    var body: some View {
        Color.clear
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    shape
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .scaleEffect(geo.size.width / size.width, anchor: .topLeading)
                }
            }
            .frame(maxWidth: size.width)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityElement(children: hasIsland ? .contain : .ignore)
            .accessibilityLabel(Text("效果演示"))
            .transition(.opacity.combined(with: .move(edge: .top)))
            .sensoryFeedback(.impact(weight: .medium), trigger: presses)
            .task(id: demo) { await run() }
    }

    @ViewBuilder
    private var shape: some View {
        if hasIsland {
            IslandBody(demo: demo, step: step, backward: backward, picker: picker, tint: tint, act: act)
        } else {
            reminder
                .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: IslandShape.reminderCorner, style: .continuous))
        }
    }

    // MARK: 动画

    /// 岛变大变小：和系统的岛一样带一点弹
    private var morph: Animation? { reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.25) }
    /// 换页、换下一笔、选好的一行出来：和真的岛一样（`IslandMotion.scroll`）
    private var scroll: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }

    /// 自己往下走：每一步等多久，到了就换（点了别的、换了状态就不等了）。选好以后的几步一步一步放
    private func run() async {
        guard hasIsland else { return }
        switch demo.phase {
        case .idle:
            guard await pause(IslandDemo.idleTime) else { return }
            withAnimation(morph) { demo.advance() }
        case .notice:
            guard await pause(IslandDemo.noticeTime) else { return }
            withAnimation(morph) { demo.advance() }
        case .compact, .picking:
            // 收起的小岛等用户长按，和真的岛一样，不自己展开
            return
        case .chosen:
            await playChosen()
        }
    }

    /// 选好以后：按钮淡出 → 选好的一行放到下面一点 → 上来 → 画圆圈 → 画对勾 → 停一下 → 下一笔或者收起
    private func playChosen() async {
        withAnimation(scroll) { step = .clearing }
        guard await pause(.milliseconds(300)) else { return }
        step = .placed
        guard await pause(.milliseconds(150)) else { return }
        withAnimation(scroll) { step = .showing }
        guard await pause(.milliseconds(400)) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = .ring }
        guard await pause(.milliseconds(250)) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { step = .check }
        guard await pause(.milliseconds(850)) else { return }
        backward = false
        withAnimation(demo.hasNext ? scroll : morph) { demo.advance() }
    }

    private func pause(_ duration: Duration) async -> Bool {
        try? await Task.sleep(for: duration)
        return !Task.isCancelled
    }

    /// 岛上点了什么
    private func act(_ action: IslandDemo.Action) {
        switch action {
        case .skipNotice:
            withAnimation(morph) { demo.advance() }
        case .expand:
            presses += 1
            withAnimation(morph) { demo.advance() }
        case .show(let page, let back):
            show(page, back: back)
        case .pick(let option, let page):
            // 选好的一行是往前走：从下面上来
            backward = false
            step = .tapped
            demo.phase = .chosen(option, from: page)
        }
    }

    /// 换页：方向变了先单独换方向，下一轮再换页，旧的一页才会照新的方向走（和真的岛 `LiveCategoryActivity.present` 一样的道理）
    private func show(_ page: LiveCategoryPicker.Page, back: Bool) {
        guard backward != back else {
            withAnimation(scroll) { demo.phase = .picking(page) }
            return
        }
        backward = back
        let animation = scroll
        Task { @MainActor in
            // 等一帧：方向先画出来
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(animation) { demo.phase = .picking(page) }
        }
    }

    /// 和真的岛一样的按钮：账本里自己的支出分类，按分类页的顺序；还没选过分类时第 1 页是前 4 个大类，有小类的点了进小类。
    /// 固定的字和真的岛一样（`LiveCategoryActivity.makePicker`）
    private var picker: LiveCategoryPicker {
        let shown = store.categories.filter { $0.type == .expense && !$0.hidden && !$0.locked }
        let ordered = { (list: [LedgerCategory]) -> [LedgerCategory] in
            list.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        }
        let groups = ordered(shown.filter { $0.parentID == nil }).map { parent in
            LiveCategoryPicker.Group(
                option: LiveCategoryPicker.Option(parent),
                children: ordered(shown.filter { $0.parentID == parent.id }).map(LiveCategoryPicker.Option.init)
            )
        }
        let quick = groups.prefix(LiveCategoryPicker.quickCount).map {
            LiveCategoryPicker.Quick(option: $0.option, opens: !$0.children.isEmpty)
        }
        let labels = LiveCategoryPicker.Labels(
            all: L("全部"), more: L("更多"), only: L("只记\("%@")"), type: CategoryType.expense.displayName.loc
        )
        return LiveCategoryPicker(quick: Array(quick), groups: groups).localized(name: \.loc, labels: labels)
    }

    // MARK: 没有灵动岛：提醒横幅

    private var reminder: some View {
        HStack(alignment: .bottom, spacing: 12) {
            NoticeBadge(tint: tint)
            NoticeText()
            NoticeRing(count: 1, tint: tint)
        }
        .padding(IslandShape.lockMargin)
        .frame(width: IslandShape.reminder.width, height: IslandShape.reminder.height)
        .dynamicTypeSize(.large)
    }
}

/// 演示走到哪了。一轮 1 笔、一轮 2 笔交替
struct IslandDemo: Hashable {
    enum Phase: Hashable {
        /// 只有摄像头
        case idle
        /// 刚开启的提醒（岛自己展开）
        case notice
        /// 收起的小岛：左边标签图标，长按展开
        case compact
        /// 展开的按钮，哪一页
        case picking(LiveCategoryPicker.Page)
        /// 选好了，从哪一页选的（按钮淡出时还要画它）
        case chosen(LiveCategoryPicker.Option, from: LiveCategoryPicker.Page)
    }

    /// 选好以后走到哪一步，和真的岛的 `ChosenStep` 一样一步一步来
    enum Step: Int, Comparable {
        /// 刚点到：按钮还在
        case tapped
        /// 按钮淡出
        case clearing
        /// 选好的一行放好，看不见、在下面一点
        case placed
        /// 选好的一行上来
        case showing
        /// 画圆圈
        case ring
        /// 画对勾
        case check

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 岛上点了什么
    enum Action {
        case skipNotice
        case expand
        case show(LiveCategoryPicker.Page, back: Bool)
        case pick(LiveCategoryPicker.Option, from: LiveCategoryPicker.Page)
    }

    static let idleTime: Duration = .milliseconds(900)
    static let noticeTime: Duration = .seconds(3)

    /// 「仅提醒」：小岛展开的是提醒，看一会儿就收回，下一轮
    var reminderOnly = false
    /// 「仅提醒」时提醒是不是长按小岛展开的（第二次出来）
    var reopened = false
    /// 第几轮：双数这一轮 1 笔，单数 2 笔
    var round = 0
    /// 这一轮的第几笔
    var index = 0
    var phase = Phase.idle

    var count: Int { round % 2 == 0 ? 1 : 2 }
    /// 还没分类的笔数，提醒的圆环里写这个
    var remaining: Int { count - index }
    /// 这一笔选好以后还有下一笔
    var hasNext: Bool { index + 1 < count }

    /// 演示用的几笔：商户和金额是假的
    var merchant: String { index == 0 ? L("便利店") : L("咖啡店") }
    var amount: String { Fmt.money(index == 0 ? 3200 : 1800, .cny) }

    /// 摄像头 → 提醒 → 小岛 → 按钮；选好 → 下一笔的按钮，这一轮完了收回只剩摄像头，下一轮。
    /// 「仅提醒」：摄像头 → 提醒 → 小岛 → 长按展开还是提醒 → 收回，下一轮
    mutating func advance() {
        switch phase {
        case .idle:
            phase = .notice
        case .notice:
            if reopened {
                nextRound()
            } else {
                phase = .compact
            }
        case .compact:
            if reminderOnly {
                reopened = true
                phase = .notice
            } else {
                phase = .picking(.quick)
            }
        case .chosen:
            if hasNext {
                index += 1
                phase = .picking(.quick)
            } else {
                nextRound()
            }
        case .picking:
            break
        }
    }

    private mutating func nextRound() {
        round += 1
        index = 0
        reopened = false
        phase = .idle
    }
}

/// 灵动岛本身：外形跟着状态变大变小（摄像头、小岛、提醒、展开），里面的东西换的时候淡入淡出、缩放一点
private struct IslandBody: View {
    let demo: IslandDemo
    let step: IslandDemo.Step
    let backward: Bool
    let picker: LiveCategoryPicker
    let tint: Color
    let act: (IslandDemo.Action) -> Void

    private enum Look { case idle, notice, compact, expanded }

    private var look: Look {
        switch demo.phase {
        case .idle: .idle
        case .notice: .notice
        case .compact: .compact
        case .picking, .chosen: .expanded
        }
    }

    private var size: CGSize {
        switch look {
        case .idle: IslandShape.camera
        case .notice: CGSize(width: IslandShape.island.width, height: IslandShape.noticeHeight)
        case .compact: IslandShape.compact
        case .expanded: IslandShape.island
        }
    }

    /// 镜头的中心离岛顶多远：展开时和顶上一行的字对齐，别的时候在小岛正中
    private var lensCenter: CGFloat {
        switch look {
        case .expanded: IslandShape.topMargin + IslandShape.header - IslandShape.headerLine / 2
        case .idle, .notice, .compact: IslandShape.camera.height / 2
        }
    }

    private var corner: CGFloat {
        switch look {
        case .idle, .compact: IslandShape.camera.height / 2
        case .notice: IslandShape.noticeCorner
        case .expanded: IslandShape.islandCorner
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch look {
            case .idle:
                Color.clear
            case .notice:
                notice.transition(IslandShape.contentSwap)
            case .compact:
                compact.transition(IslandShape.contentSwap)
            case .expanded:
                IslandExpanded(demo: demo, step: step, backward: backward, picker: picker, tint: tint, act: act)
                    .transition(IslandShape.contentSwap)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        // 收起的小岛只往左边多出一块放图标，右边到摄像头为止
        .offset(x: look == .compact ? -IslandShape.compactLead / 2 : 0)
        // 摄像头不跟着小岛挪：放在挪之前的位置上（offset 不改排版的位置）
        .overlay(alignment: .top) { IslandCamera(centerY: lensCenter) }
        .dynamicTypeSize(.large)
    }

    /// 照 AirPods 连上时的样子：图标和圆环做满摄像头两边，上沿离岛顶约 20，两行字的下沿和它们对齐。
    /// 点一下往下走（收成小岛；「仅提醒」长按展开的那次是收回）
    private var notice: some View {
        HStack(alignment: .bottom, spacing: 0) {
            NoticeBadge(tint: tint)
            NoticeText()
                .padding(.leading, IslandShape.badgeTextGap)
            NoticeRing(count: demo.remaining, tint: tint)
        }
        .padding(.horizontal, IslandShape.noticeInset)
        .padding(.top, IslandShape.topMargin + IslandShape.noticeDrop)
        .frame(width: IslandShape.island.width, height: IslandShape.noticeHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { act(.skipNotice) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// 收起的小岛：左边标签图标（还没选分类），右边到摄像头为止。长按展开，和真的岛一样，不长按就一直收着
    private var compact: some View {
        HStack {
            Image(systemName: LiveCategoryPicker.unpickedSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IslandShape.compactInset)
        .frame(width: IslandShape.compact.width, height: IslandShape.compact.height)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.3) { act(.expand) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("选分类"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { act(.expand) }
    }
}

/// 展开的岛：顶上一行（商户或返回、金额）和下面的按钮或选好的一行。
/// 换页、换下一笔时左边、右边、下面各自在自己的范围里整页滚过去，滚出去的部分切掉
private struct IslandExpanded: View {
    let demo: IslandDemo
    let step: IslandDemo.Step
    let backward: Bool
    let picker: LiveCategoryPicker
    let tint: Color
    let act: (IslandDemo.Action) -> Void

    /// 每一部分换的时候用的 id：哪一笔、哪一页
    private struct Key: Hashable {
        var index: Int
        var page: LiveCategoryPicker.Page?
    }

    private var swap: AnyTransition { .push(from: backward ? .top : .bottom) }

    private var page: LiveCategoryPicker.Page? {
        if case .picking(let page) = demo.phase { return page }
        return nil
    }

    private var chosen: LiveCategoryPicker.Option? {
        if case .chosen(let option, _) = demo.phase { return option }
        return nil
    }

    /// 下面的按钮：选好以后淡出完才拿掉
    private var gridPage: LiveCategoryPicker.Page? {
        switch demo.phase {
        case .picking(let page): page
        case .chosen(_, let from) where step < .placed: from
        default: nil
        }
    }

    /// 左上角：第 2、3 页是返回和标题，第 1 页和选好以后是商户
    private var headerScreen: LiveCategoryPicker.Screen? {
        guard let page else { return nil }
        let screen = picker.screen(page)
        return screen.back == nil ? nil : screen
    }

    var body: some View {
        VStack(spacing: IslandShape.systemGap) {
            header
            bottom
        }
        .padding(.horizontal, IslandShape.sideMargin)
        .padding(.top, IslandShape.topMargin)
        .padding(.bottom, IslandShape.bottomMargin)
        .frame(width: IslandShape.island.width, height: IslandShape.island.height, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                IslandHeaderLeading(merchant: demo.merchant, screen: headerScreen) { act(.show($0, back: true)) }
                    .id(Key(index: demo.index, page: headerScreen?.page))
                    .transition(swap)
            }
            .clipped()
            Spacer(minLength: IslandShape.cameraWidth + 16)
            ZStack(alignment: .trailing) {
                Text(verbatim: demo.amount)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .id(demo.index)
                    .transition(swap)
            }
            .clipped()
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(height: IslandShape.headerLine)
        .padding(.horizontal, IslandShape.headerInset)
        .padding(.top, IslandShape.header - IslandShape.headerLine)
    }

    private var bottom: some View {
        ZStack {
            if let gridPage {
                IslandGrid(cells: picker.screen(gridPage).cells, tint: tint) { tap($0, on: gridPage) }
                    .opacity(step >= .clearing && chosen != nil ? 0 : 1)
                    .allowsHitTesting(page != nil)
                    .id(Key(index: demo.index, page: gridPage))
                    .transition(swap)
            }
            if let chosen {
                ChosenLine(option: chosen, step: step, tint: tint)
                    .opacity(step >= .showing ? 1 : 0)
                    .offset(y: step <= .placed ? IslandShape.revealRise : 0)
                    .id(demo.index)
                    .transition(swap)
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandShape.grid, maxHeight: IslandShape.grid)
        .clipped()
    }

    private func tap(_ cell: LiveCategoryPicker.Cell, on page: LiveCategoryPicker.Page) {
        switch cell.action {
        case .show(let next):
            act(.show(next, back: false))
        case .pick(let id):
            if let option = picker.option(id) { act(.pick(option, from: page)) }
        }
    }
}

/// 顶上一行左边：第 2、3 页是返回和标题，别的时候是商户
private struct IslandHeaderLeading: View {
    let merchant: String
    let screen: LiveCategoryPicker.Screen?
    let back: (LiveCategoryPicker.Page) -> Void

    var body: some View {
        if let screen, let page = screen.back {
            Button { back(page) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: IslandShape.backCircle, height: IslandShape.backCircle)
                        .background(Color.white.opacity(0.14), in: Circle())
                    if let title = screen.title {
                        Text(verbatim: title).lineLimit(1)
                    }
                }
                .frame(minWidth: 44, minHeight: IslandShape.headerLine, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("返回"))
        } else {
            Text(verbatim: merchant)
                .lineLimit(1)
                .frame(minHeight: IslandShape.headerLine)
        }
    }
}

/// 一行 5 个，不满一行的靠左，整块居中；不管几行都占两行的高度，上下居中
private struct IslandGrid: View {
    let cells: [LiveCategoryPicker.Cell]
    let tint: Color
    let tap: (LiveCategoryPicker.Cell) -> Void

    private var rows: [[LiveCategoryPicker.Cell]] {
        stride(from: 0, to: cells.count, by: LiveCategoryPicker.perRow).map {
            Array(cells[$0..<min($0 + LiveCategoryPicker.perRow, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandShape.rowSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: IslandShape.columnSpacing) {
                    ForEach(rows[row], id: \.self) { cell in
                        IslandCell(cell: cell, tint: tint) { tap(cell) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandShape.grid, maxHeight: IslandShape.grid)
    }
}

/// 按钮 60 × 44：圆 28 里放图标，字在圆下面。分类是主题色的圆，「全部」「更多」是白色的圆
private struct IslandCell: View {
    let cell: LiveCategoryPicker.Cell
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: cell.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(cell.isNavigation ? Color.white : tint)
                    .frame(width: IslandShape.circle, height: IslandShape.circle)
                    .background(cell.isNavigation ? Color.white.opacity(0.14) : tint.opacity(0.22), in: Circle())
                Text(verbatim: cell.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: IslandShape.cell.width, height: IslandShape.cell.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 选好的一行：左边主题色圆里是分类图标，中间「已分类」和分类名，
/// 右边像面容 ID 认出来那样：圆圈从 12 点顺时针画一圈，接着画出对勾（`ChosenCheck`）
private struct ChosenLine: View {
    let option: LiveCategoryPicker.Option
    let step: IslandDemo.Step
    let tint: Color

    var body: some View {
        HStack(spacing: IslandShape.chosenGap) {
            Image(systemName: option.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: IslandShape.chosenBadge, height: IslandShape.chosenBadge)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("已分类")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(verbatim: option.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle()
                    .inset(by: IslandShape.chosenBadge / 20)
                    .trim(from: 0, to: step >= .ring ? 1 : 0)
                    .stroke(tint, lineWidth: IslandShape.chosenRing)
                    .rotationEffect(.degrees(-90))
                IslandCheck()
                    .trim(from: 0, to: step >= .check ? 1 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: IslandShape.checkLine, lineCap: .round, lineJoin: .round))
                    .frame(width: IslandShape.check, height: IslandShape.check)
            }
            .frame(width: IslandShape.chosenBadge, height: IslandShape.chosenBadge)
        }
        .padding(.horizontal, IslandShape.chosenInset)
        .frame(maxWidth: .infinity, minHeight: IslandShape.grid, maxHeight: IslandShape.grid)
    }
}

/// 对勾：和岛上的 `CheckShape` 一样，24 × 24 里 (5, 12.5) → (9.5, 17) → (19, 7.5)，从左往右画
private struct IslandCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        let points = [CGPoint(x: 5, y: 12.5), CGPoint(x: 9.5, y: 17), CGPoint(x: 19, y: 7.5)]
        var path = Path()
        path.addLines(points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
        return path
    }
}

/// 提醒左边：主题色收据图标
private struct NoticeBadge: View {
    let tint: Color

    var body: some View {
        Image(systemName: "receipt.fill")
            .font(.system(size: 42))
            .foregroundStyle(tint)
            .frame(width: IslandShape.badge, height: IslandShape.badge)
    }
}

/// 提醒中间：灰色「刚刚记了一笔」，白色「待分类」
private struct NoticeText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("刚刚记了一笔")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("待分类")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 提醒右边：主题色圆环，里面是还没分类的笔数
private struct NoticeRing: View {
    let count: Int
    let tint: Color

    var body: some View {
        Circle()
            .strokeBorder(tint, lineWidth: IslandShape.ringLine)
            .frame(width: IslandShape.badge, height: IslandShape.badge)
            .overlay {
                Text(verbatim: String(count))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
    }
}

/// 摄像头：岛正中顶上那一块，镜头在它右半边。上下跟着岛里的字（`IslandBody.lensCenter`）
private struct IslandCamera: View {
    let centerY: CGFloat

    var body: some View {
        Circle()
            .fill(Color(white: 0.09))
            .overlay { Circle().strokeBorder(Color(white: 0.2), lineWidth: 1) }
            .frame(width: IslandShape.lens, height: IslandShape.lens)
            .offset(x: IslandShape.lensOffset, y: centerY - IslandShape.lens / 2)
            .accessibilityHidden(true)
    }
}

/// 和 `IslandLayout`（小组件扩展里）一样的数，App 这边拿不到那个文件，抄一份
private enum IslandShape {
    /// 岛：深色模式的页面是黑的，换成深灰才看得见
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .black })
    /// 岛变大变小时里面的东西：淡入淡出，从顶上缩放一点
    static var contentSwap: AnyTransition { .opacity.combined(with: .scale(scale: 0.85, anchor: .top)) }

    static let cell = CGSize(width: 60, height: 44)
    static let circle: CGFloat = 28
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    static let grid: CGFloat = cell.height * 2 + rowSpacing
    static let header: CGFloat = 32
    static let headerLine: CGFloat = 28
    static let headerInset: CGFloat = 10
    static let backCircle: CGFloat = 24
    static let sideMargin: CGFloat = 19
    static let topMargin: CGFloat = 10
    static let bottomMargin: CGFloat = 16
    /// 摄像头那一行和按钮之间系统空的
    static let systemGap: CGFloat = 8
    static let island = CGSize(width: 371, height: topMargin + header + systemGap + grid + bottomMargin)
    /// 岛的圆角（真机截图量的黑边圆角）
    static let islandCorner: CGFloat = 48
    /// 只有摄像头时的岛（收起来没有实时活动）；镜头在它右半边
    static let camera = CGSize(width: 126, height: 37)
    static let cameraWidth: CGFloat = camera.width
    static let lens: CGFloat = 12
    static let lensOffset: CGFloat = 40
    /// 收起的小岛：摄像头左边多出一块放图标，右边没有东西就不多出来
    static let compactLead: CGFloat = 44
    static let compact = CGSize(width: camera.width + compactLead, height: 37)
    static let compactInset: CGFloat = 14

    /// 提醒：图标和圆环 56，圆心离岛边约 44（左右各缩 16），上沿离岛顶 10 + 10；岛的圆角 44
    static let badge: CGFloat = 56
    static let noticeDrop: CGFloat = 10
    static let noticeInset: CGFloat = 16
    static let badgeTextGap: CGFloat = 10
    static let ringLine: CGFloat = 5.5
    static let noticeHeight: CGFloat = 95
    static let noticeCorner: CGFloat = 44

    /// 选好的一行
    static let chosenBadge: CGFloat = 60
    static let chosenInset: CGFloat = 8
    static let chosenGap: CGFloat = 14
    static let chosenRing: CGFloat = 5
    static let check: CGFloat = 32
    static let checkLine: CGFloat = 3.8
    /// 选好的一行出来时从下面多远上来
    static let revealRise: CGFloat = 16

    static let lockMargin: CGFloat = 14
    static let reminder = CGSize(width: 371, height: badge + lockMargin * 2)
    static let reminderCorner: CGFloat = 24
}
