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
/// - 展开（提醒更新时系统自动展开、长按岛展开）：摄像头两边是顶上一行（第 1 页商户、账户，第 2、3 页返回和标题；右边金额），下面是按钮，一行 6 个；
/// - 按钮：分类是主题色的圆和图标，「全部」「更多」是白色的圆，字在圆下面；
/// - 收起：左边是分类图标（还没选是统一的图标），右边是金额；minimal 只放图标；
/// - 锁屏：黑色卡片，同样的三页和按钮。
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
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AmountText(amount: context.state.amount)
                        .frame(height: IslandLayout.header)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PickerBody(state: context.state)
                        .padding(.top, IslandLayout.headerGap)
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
            .contentMargins(.top, IslandLayout.verticalMargin, for: .expanded)
            .contentMargins(.bottom, IslandLayout.verticalMargin, for: .expanded)
            .keylineTint(context.state.tintColor)
            .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        }
    }
}

/// Apple 规范：展开和锁屏宽 371 点（Pro Max、Plus 408），高 84–160 点。
/// 按钮 60 × 48（圆 30、图标 15、字 12），一行 5 个、间隔 8，宽 332；两行高 48 + 6 + 48 = 102。
/// 展开：上下边距 10 + 顶上一行 32 + 间隔 4 + 102 = 158；锁屏：10 + 30 + 6 + 102 + 10 = 158
enum IslandLayout {
    static let cell = CGSize(width: 60, height: 48)
    static let circle: CGFloat = 30
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 6
    static let header: CGFloat = 32
    static let headerGap: CGFloat = 4
    static let sideMargin: CGFloat = 19
    static let verticalMargin: CGFloat = 10
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

/// 第 1 页：商户、账户（展开时两行，锁屏一行）；第 2、3 页：返回和标题。选好了回到商户、账户。
/// 只有一行的字（「支出」「饮食」、没有商户时的账户、锁屏上的商户）和右边的金额一样大（`IslandLayout.lineFont`）
struct HeaderLeading: View {
    let state: CategoryActivityAttributes.ContentState
    let inline: Bool

    var body: some View {
        if state.chosen == nil, let back = state.screen.back {
            Button(intent: ShowLiveCategoryPageIntent(recordID: state.recordID, page: back)) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.14), in: Circle())
                    if let title = state.screen.title {
                        Text(title)
                            .font(IslandLayout.lineFont)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: IslandLayout.header, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if state.merchant == nil {
            Text(state.account)
                .font(IslandLayout.lineFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: inline ? nil : IslandLayout.header, alignment: .leading)
        } else if inline {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state.merchant ?? state.account)
                    .font(IslandLayout.lineFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if state.merchant != nil {
                    Text(state.account)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(state.merchant ?? state.account)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if state.merchant != nil {
                    Text(state.account)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(height: IslandLayout.header, alignment: .leading)
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

/// 按钮；选好了显示选中的分类
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
        .dynamicTypeSize(...IslandLayout.largestType)
    }
}

/// 一行 5 个（`LiveCategoryPicker.perRow`）；不满一行的靠左，整块居中
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

/// 按钮 60 × 48：圆 30 里放图标，字（12 点）在圆下面。分类：主题色 22% 的圆、主题色图标；「全部」「更多」：白色 14% 的圆、白色图标
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
        VStack(spacing: 3) {
            Image(systemName: cell.symbol)
                .font(.system(size: 15, weight: .semibold))
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

/// 锁屏卡片：黑色 80%，和岛上一样的按钮。高 10 + 30 + 6 + 102 + 10 = 158，不超过上限
struct LockScreenCard: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                HeaderLeading(state: state, inline: true)
                Spacer(minLength: 8)
                AmountText(amount: state.amount)
            }
            .frame(height: 30)
            PickerBody(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dynamicTypeSize(...IslandLayout.largestType)
        .environment(\.colorScheme, .dark)
    }
}
