import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import BKModel

@main
struct CategoryActivityBundle: WidgetBundle {
    var body: some Widget {
        CategoryActivityWidget()
    }
}

/// 灵动岛选分类（ADR 0024）：自动记账记上一笔没分类的支出或收入后，App 开启这个实时活动，在岛上和锁屏上选分类。
///
/// - 展开（长按岛展开）：摄像头两边是顶上一行（第 1 页商户，第 2、3 页返回和标题；右边金额），下面是按钮，一行 5 个；
/// - 按钮：分类是主题色的圆和图标，「全部」「更多」是白色的圆，字在圆下面；
/// - 收起：左边是分类图标（还没选是统一的图标），右边是金额；minimal 只放图标；
/// - 锁屏：黑色卡片，同样的三页和按钮；
/// - 换页、选好、换下一笔：整页上下滚过去，返回时反过来（`IslandMotion`）。
///
/// 按钮都是 `LiveActivityIntent`，在 App 进程里运行，不打开 App。单点岛或卡片打开 App 里这一笔的选分类面板。
/// 扩展只照着内容显示（`CategoryActivityAttributes.ContentState`），不读账本、不翻译
struct CategoryActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CategoryActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HeaderLeading(state: context.state, inline: false)
                        .islandSwap(context.state.headerKey, back: context.state.isBack)
                        .islandHeader(.leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AmountText(amount: context.state.amount)
                        .islandSwap(context.state.recordID, back: context.state.isBack)
                        .islandHeader(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PickerBody(state: context.state)
                        .islandSwap(context.state.screenKey, back: context.state.isBack)
                }
            } compactLeading: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(context.state.tintColor)
            } compactTrailing: {
                Text(context.state.amount)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 76)
            } minimal: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(context.state.tintColor)
            }
            .contentMargins(.horizontal, IslandLayout.sideMargin, for: .expanded)
            .contentMargins(.top, IslandLayout.topMargin, for: .expanded)
            .contentMargins(.bottom, IslandLayout.bottomMargin, for: .expanded)
            .keylineTint(context.state.tintColor)
            .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        }
    }
}

/// Apple 规范：展开和锁屏宽 371 点（Pro Max、Plus 408），高 84–160 点，超出的部分系统直接切掉。
/// 真机截图量出来（展开）：
/// - 只显示离黑边约 13 点以内的部分，四个角是半径约 35 的圆角（黑边的圆角约 48），外面那一圈黑边上的东西被切掉；
/// - 摄像头那一行和下面的按钮之间系统还要空约 8 点。
/// 按钮 60 × 44（圆 28、图标 14、字 12），一行 5 个、间隔 4，宽 316，两边的按钮离黑边远一些，第二行的字不碰下面两个角；两行高 44 + 4 + 44 = 92。
/// 上边距 10 + 顶上一行 32 + 系统 8 + 92 + 下边距 16 ≈ 158：第二行的字离黑边约 18 点。
/// 顶上一行的东西放在下面 28 点里、左右各往里缩 10 点，返回、商户和金额不碰上面两个角。
/// 锁屏没有摄像头：10 + 30 + 6 + 92 + 10 = 148
///
/// 每一页（还有选好的样子）都占两行按钮的高度：第 1 页只有一行时上下居中，空出来的地方留白。
/// 以前第 1 页一行、「全部」两行，换页时岛跟着变高变矮，系统缩放岛时整块重排，金额也跟着动，动画乱；现在一笔从开始到选好岛的大小不变
enum IslandLayout {
    static let cell = CGSize(width: 60, height: 44)
    static let circle: CGFloat = 28
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    /// 按钮区固定的高度：一屏最多的行数（两行）
    static let grid: CGFloat = {
        let rows = CGFloat(LiveCategoryPicker.perScreen / LiveCategoryPicker.perRow)
        return cell.height * rows + rowSpacing * (rows - 1)
    }()
    /// 顶上一行占的高度；里面的东西放在下面 `headerLine` 里
    static let header: CGFloat = 32
    static let headerLine: CGFloat = 28
    static let headerInset: CGFloat = 10
    static let backCircle: CGFloat = 24
    static let sideMargin: CGFloat = 19
    static let topMargin: CGFloat = 10
    static let bottomMargin: CGFloat = 16
    /// 摄像头两边只有一行的字和金额用同一个字号
    static let lineFont = Font.headline
    /// 字号跟系统走，但不超过这一档：再大两行按钮放不进 160 点
    static let largestType: DynamicTypeSize = .large
}

extension CategoryActivityAttributes.ContentState {
    /// App 的主题色（`ThemeColor`）；以前开的活动没写，用蓝色
    var tintColor: Color {
        switch tint {
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "brown": .brown
        case "graphite": .gray
        default: .blue
        }
    }
}

extension CategoryActivityAttributes.ContentState {
    /// 下面的按钮：换页、选好、换下一笔时变
    var screenKey: String { "\(recordID)|\(screen.page.token)|\(chosen?.id ?? "")" }

    /// 左上角：返回和标题跟着页变；商户只在换下一笔时变（第 1 页选好了还是这个商户，不用动）
    var headerKey: String {
        chosen == nil && screen.back != nil ? "\(recordID)|\(screen.page.token)" : recordID
    }
}

/// 换页、选好、换下一笔：像翻桌面那样整页滚过去，只是上下滚。
/// 往前（点进去、「更多」、选好、下一笔）旧的往上滚走、新的从下面上来；返回反过来，新的从上面下来。
/// 系统让旧内容按它自己身上的方向离开，所以方向变了 App 先单独更新一次方向，再换内容（`LiveCategoryActivity.present`）。
/// 系统给小组件和实时活动的动画最长 2 秒；常亮显示（Always On）时系统不做动画
enum IslandMotion {
    static let scroll: Animation = .smooth(duration: 0.35)

    static func page(back: Bool) -> AnyTransition {
        .push(from: back ? .top : .bottom)
    }
}

extension View {
    /// `key` 变了就整页滚过去；只在自己的范围里滚，滚出去的部分切掉，不压到别的东西上
    func islandSwap<Key: Hashable>(_ key: Key, back: Bool) -> some View {
        ZStack {
            self.id(key).transition(IslandMotion.page(back: back))
        }
        .clipped()
        .animation(IslandMotion.scroll, value: key)
    }

    /// 岛上顶上一行：占 32 高，东西放在下面 28 里，再往岛中间缩 10 点，不碰岛的上面两个角
    func islandHeader(_ edge: HorizontalEdge) -> some View {
        let side: Edge.Set = edge == .leading ? .leading : .trailing
        return frame(height: IslandLayout.headerLine, alignment: .center)
            .padding(side, IslandLayout.headerInset)
            .padding(.top, IslandLayout.header - IslandLayout.headerLine)
    }
}

/// 第 1 页：岛上只有商户（没有商户是账户），锁屏是商户和账户；第 2、3 页：返回和标题。选好了回到第 1 页的样子。
/// 岛上放不下两行：两行的字顶到岛上面的黑边，会被切掉。
/// 这一行的字和右边的金额一样大（`IslandLayout.lineFont`），锁屏上商户后面的账户小一号
struct HeaderLeading: View {
    let state: CategoryActivityAttributes.ContentState
    let inline: Bool

    var body: some View {
        if state.chosen == nil, let back = state.screen.back {
            Button(intent: ShowLiveCategoryPageIntent(recordID: state.recordID, page: back)) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: IslandLayout.backCircle, height: IslandLayout.backCircle)
                        .background(Color.white.opacity(0.14), in: Circle())
                    if let title = state.screen.title {
                        Text(title)
                            .font(IslandLayout.lineFont)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: IslandLayout.headerLine, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if inline, let merchant = state.merchant {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(merchant)
                    .font(IslandLayout.lineFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.account)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        } else {
            Text(state.merchant ?? state.account)
                .font(IslandLayout.lineFont)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

struct AmountText: View {
    let amount: String

    var body: some View {
        Text(amount)
            .font(IslandLayout.lineFont)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// 按钮；选好了显示选中的分类。不管几行都占两行的高度，内容上下居中（`IslandLayout.grid`）
struct PickerBody: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        Group {
            if let chosen = state.chosen {
                HStack(spacing: 10) {
                    Image(systemName: chosen.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(state.tintColor, in: Circle())
                    Text(chosen.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(state.tintColor)
                }
                .frame(maxWidth: .infinity, minHeight: IslandLayout.cell.height)
            } else {
                CellGrid(recordID: state.recordID, cells: state.screen.cells, tint: state.tintColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandLayout.grid, maxHeight: IslandLayout.grid)
        .dynamicTypeSize(...IslandLayout.largestType)
    }
}

/// 一行 5 个（`LiveCategoryPicker.perRow`）；不满一行的靠左，整块居中；只有一行时在两行的高度里上下居中（`PickerBody`）
struct CellGrid: View {
    let recordID: String
    let cells: [LiveCategoryPicker.Cell]
    let tint: Color

    private var rows: [[LiveCategoryPicker.Cell]] {
        stride(from: 0, to: cells.count, by: LiveCategoryPicker.perRow).map {
            Array(cells[$0..<min($0 + LiveCategoryPicker.perRow, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.rowSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: IslandLayout.columnSpacing) {
                    ForEach(0..<rows[row].count, id: \.self) { index in
                        CellButton(recordID: recordID, cell: rows[row][index], tint: tint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 按钮 60 × 44：圆 28 里放图标，字（12 点）在圆下面。分类：主题色 22% 的圆、主题色图标；「全部」「更多」：白色 14% 的圆、白色图标
struct CellButton: View {
    let recordID: String
    let cell: LiveCategoryPicker.Cell
    let tint: Color

    var body: some View {
        switch cell.action {
        case .pick(let categoryID):
            Button(intent: PickLiveCategoryIntent(recordID: recordID, categoryID: categoryID)) { label }
                .buttonStyle(.plain)
        case .show(let page):
            Button(intent: ShowLiveCategoryPageIntent(recordID: recordID, page: page)) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
        VStack(spacing: 2) {
            Image(systemName: cell.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(cell.isNavigation ? Color.white : tint)
                .frame(width: IslandLayout.circle, height: IslandLayout.circle)
                .background(cell.isNavigation ? Color.white.opacity(0.14) : tint.opacity(0.22), in: Circle())
            Text(cell.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: IslandLayout.cell.width, height: IslandLayout.cell.height)
        .contentShape(Rectangle())
    }
}

/// 锁屏卡片：黑色 80%，和岛上一样的按钮。高 10 + 30 + 6 + 92 + 10 = 148，不超过上限
struct LockScreenCard: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                HeaderLeading(state: state, inline: true)
                    .islandSwap(state.headerKey, back: state.isBack)
                Spacer(minLength: 8)
                AmountText(amount: state.amount)
                    .islandSwap(state.recordID, back: state.isBack)
            }
            .frame(height: 30)
            PickerBody(state: state)
                .islandSwap(state.screenKey, back: state.isBack)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dynamicTypeSize(...IslandLayout.largestType)
        .environment(\.colorScheme, .dark)
    }
}
