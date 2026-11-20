import SwiftUI
import UIKit
import BKModel

/// 「我的 › 通知 › 灵动岛」打开时下面的演示（ADR 0024）：一个能点的岛，没有底色，自己浮在设置项下面。
///
/// 和真的岛一样走一遍，不做动画（直接换）：
/// 1. 先是提醒：左边收据图标，中间「刚刚记了一笔 / 待分类」，右边圆环里是还有几笔没分类；3 秒后（真的岛也是 3 秒，`openingTime`）换成按钮，点一下也换；
/// 2. 按钮三页：第 1 页 4 个推荐和「全部」，「全部」是全部大类，点有小类的大类进小类，左上角返回。
///    分类是账本里自己的支出分类，页怎么分、按钮点了去哪用的就是岛上那一套（`LiveCategoryPicker`）；
/// 3. 点到分类：按钮换成选好的一行（分类图标、「已分类」和分类名、圆圈和对勾），停一下，还有下一笔就换成下一笔的按钮；
/// 4. 一轮选完从提醒重新开始。一轮 1 笔、下一轮 2 笔，这样交替，一笔和连着几笔的样子都看得到。不记账。
///
/// 尺寸照 `CategoryActivity` 里的 `IslandLayout`：按钮的岛宽 371、高 10 + 32 + 8 + 92 + 16 = 158，提醒的岛矮一些（约 95）。
/// 按真的尺寸画好再整体缩到这一行的宽度，元素之间的比例和真机一样；这一行一直留着 158 高，岛变矮时下面的东西不跳。
/// 没有灵动岛的手机画待分类的提醒横幅（`ReminderCard`），不能点。
/// 岛是黑色的；深色模式下页面也是黑的，岛换成深灰，跟着外观实时换
struct IslandPreview: View {
    let hasIsland: Bool

    @Environment(LedgerStore.self) private var store
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue
    @State private var demo = IslandDemo()

    private var tint: Color { ThemeColor.color(stored: themeColor) }
    private var size: CGSize { hasIsland ? IslandShape.island : IslandShape.reminder }

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
            .task(id: demo) { await advanceLater() }
    }

    @ViewBuilder
    private var shape: some View {
        if hasIsland {
            IslandBody(demo: $demo, picker: picker, tint: tint)
        } else {
            reminder
                .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: IslandShape.reminderCorner, style: .continuous))
        }
    }

    /// 提醒放 3 秒换按钮；选好的停一下换下一笔，一轮完了重新开始。点了别的（换了状态）就不等了
    private func advanceLater() async {
        guard hasIsland else { return }
        let wait: Duration
        switch demo.phase {
        case .notice: wait = IslandDemo.noticeTime
        case .chosen: wait = IslandDemo.chosenTime
        case .picking: return
        }
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled else { return }
        demo.advance()
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
        /// 刚开启的提醒
        case notice
        /// 按钮的哪一页
        case picking(LiveCategoryPicker.Page)
        /// 选好了，显示一下
        case chosen(LiveCategoryPicker.Option)
    }

    static let noticeTime: Duration = .seconds(3)
    static let chosenTime: Duration = .milliseconds(1400)

    /// 第几轮：双数这一轮 1 笔，单数 2 笔
    var round = 0
    /// 这一轮的第几笔
    var index = 0
    var phase = Phase.notice

    var count: Int { round % 2 == 0 ? 1 : 2 }
    /// 还没分类的笔数，提醒的圆环里写这个
    var remaining: Int { count - index }

    /// 演示用的几笔：商户和金额是假的
    var merchant: String { index == 0 ? L("便利店") : L("咖啡店") }
    var amount: String { Fmt.money(index == 0 ? 3200 : 1800, .cny) }

    /// 提醒 → 按钮；选好 → 下一笔的按钮，这一轮完了下一轮的提醒
    mutating func advance() {
        switch phase {
        case .notice:
            phase = .picking(.quick)
        case .chosen:
            if index + 1 < count {
                index += 1
                phase = .picking(.quick)
            } else {
                round += 1
                index = 0
                phase = .notice
            }
        case .picking:
            break
        }
    }
}

/// 灵动岛本身：提醒、按钮、选好三种样子，摄像头在正中
private struct IslandBody: View {
    @Binding var demo: IslandDemo
    let picker: LiveCategoryPicker
    let tint: Color

    var body: some View {
        content
            .frame(width: IslandShape.island.width, height: height, alignment: .top)
            .overlay(alignment: .top) { IslandCamera() }
            .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .dynamicTypeSize(.large)
    }

    private var isNotice: Bool { demo.phase == .notice }
    private var height: CGFloat { isNotice ? IslandShape.noticeHeight : IslandShape.island.height }
    private var corner: CGFloat { isNotice ? IslandShape.noticeCorner : IslandShape.islandCorner }

    @ViewBuilder
    private var content: some View {
        switch demo.phase {
        case .notice:
            notice
        case .picking(let page):
            pickerPage(picker.screen(page))
        case .chosen(let option):
            VStack(spacing: IslandShape.systemGap) {
                IslandHeader(merchant: demo.merchant, amount: demo.amount, screen: nil) { _ in }
                ChosenLine(option: option, tint: tint)
            }
            .islandMargins()
        }
    }

    /// 照 AirPods 连上时的样子：图标和圆环做满摄像头两边，上沿离岛顶约 20，两行字的下沿和它们对齐。点一下直接换成按钮
    private var notice: some View {
        HStack(alignment: .bottom, spacing: 0) {
            NoticeBadge(tint: tint)
            NoticeText()
                .padding(.leading, IslandShape.badgeTextGap)
            NoticeRing(count: demo.remaining, tint: tint)
        }
        .padding(.horizontal, IslandShape.noticeInset)
        .padding(.top, IslandShape.topMargin + IslandShape.noticeDrop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { demo.advance() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func pickerPage(_ screen: LiveCategoryPicker.Screen) -> some View {
        VStack(spacing: IslandShape.systemGap) {
            IslandHeader(merchant: demo.merchant, amount: demo.amount, screen: screen) { demo.phase = .picking($0) }
            IslandGrid(cells: screen.cells, tint: tint, tap: tap)
        }
        .islandMargins()
    }

    private func tap(_ cell: LiveCategoryPicker.Cell) {
        switch cell.action {
        case .show(let page):
            demo.phase = .picking(page)
        case .pick(let id):
            if let option = picker.option(id) { demo.phase = .chosen(option) }
        }
    }
}

/// 顶上一行：第 1 页、选好时是商户，第 2、3 页是返回和标题；右边一直是金额。摄像头那一块空着
private struct IslandHeader: View {
    let merchant: String
    let amount: String
    let screen: LiveCategoryPicker.Screen?
    let back: (LiveCategoryPicker.Page) -> Void

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: IslandShape.cameraWidth + 16)
            Text(verbatim: amount)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(height: IslandShape.headerLine)
        .padding(.horizontal, IslandShape.headerInset)
        .padding(.top, IslandShape.header - IslandShape.headerLine)
    }

    @ViewBuilder
    private var leading: some View {
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
            Text(verbatim: merchant).lineLimit(1)
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

/// 选好的一行：左边主题色圆里是分类图标，中间「已分类」和分类名，右边画好的圆圈和对勾（真的岛上是一笔一笔画出来的，这里直接放）
private struct ChosenLine: View {
    let option: LiveCategoryPicker.Option
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
                    .stroke(tint, lineWidth: IslandShape.chosenRing)
                IslandCheck()
                    .stroke(tint, style: StrokeStyle(lineWidth: IslandShape.checkLine, lineCap: .round, lineJoin: .round))
                    .frame(width: IslandShape.check, height: IslandShape.check)
            }
            .frame(width: IslandShape.chosenBadge, height: IslandShape.chosenBadge)
        }
        .padding(.horizontal, IslandShape.chosenInset)
        .frame(maxWidth: .infinity, minHeight: IslandShape.grid, maxHeight: IslandShape.grid)
    }
}

/// 对勾：和岛上的 `CheckShape` 一样，24 × 24 里 (5, 12.5) → (9.5, 17) → (19, 7.5)
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

/// 摄像头：岛正中顶上那一块，镜头在它右半边
private struct IslandCamera: View {
    var body: some View {
        Circle()
            .fill(Color(white: 0.09))
            .overlay { Circle().strokeBorder(Color(white: 0.2), lineWidth: 1) }
            .frame(width: IslandShape.lens, height: IslandShape.lens)
            .offset(x: IslandShape.lensOffset, y: (IslandShape.cameraHeight - IslandShape.lens) / 2)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// 按钮和选好的岛：左右 19、上 10、下 16
    func islandMargins() -> some View {
        padding(.horizontal, IslandShape.sideMargin)
            .padding(.top, IslandShape.topMargin)
            .padding(.bottom, IslandShape.bottomMargin)
    }
}

/// 和 `IslandLayout`（小组件扩展里）一样的数，App 这边拿不到那个文件，抄一份
private enum IslandShape {
    /// 岛：深色模式的页面是黑的，换成深灰才看得见
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .black })

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
    /// 摄像头（收起的岛）多宽多高；镜头在它右半边
    static let cameraWidth: CGFloat = 126
    static let cameraHeight: CGFloat = 37
    static let lens: CGFloat = 12
    static let lensOffset: CGFloat = 40

    /// 提醒：图标和圆环 56，圆心离岛边约 44（左右各缩 16），上沿离岛顶 10 + 10，下面留 19；岛的圆角 44
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

    static let lockMargin: CGFloat = 14
    static let reminder = CGSize(width: 371, height: badge + lockMargin * 2)
    static let reminderCorner: CGFloat = 24
}
