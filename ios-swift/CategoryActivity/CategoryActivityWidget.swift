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
/// - 展开（提醒更新时系统自动展开、长按岛展开）：第 1 页顶上是商户、账户和金额，第 2、3 页左上角是返回和标题；下面是按钮，一行 6 个；
/// - 收起：左边是分类图标（还没选是统一的图标），右边是金额；minimal 只放图标；
/// - 锁屏：同样的三页和按钮。
///
/// 按钮都是 `LiveActivityIntent`，在 App 进程里运行，不打开 App。单点岛或卡片打开 App 里这一笔的选分类面板。
/// 扩展只照着内容显示（`CategoryActivityAttributes.ContentState`），不读账本、不翻译
struct CategoryActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CategoryActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HeaderLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AmountText(amount: context.state.amount)
                        .frame(minHeight: IslandLayout.header)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PickerBody(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
            } compactTrailing: {
                Text(context.state.amount)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 72)
            } minimal: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
            }
            .contentMargins(.horizontal, IslandLayout.islandMargin, for: .expanded)
            .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        }
    }
}

/// Apple 规范：展开和锁屏宽 371 点（Pro Max、Plus 408），高 84–160 点；按钮不小于 44 点。
/// 一行 6 个 52 × 46 的按钮、间隔 4，宽 332；两行加顶上一行高约 150
enum IslandLayout {
    static let cell = CGSize(width: 52, height: 46)
    static let spacing: CGFloat = 4
    static let header: CGFloat = 44
    static let islandMargin: CGFloat = 14
}

/// 第 1 页：商户、账户；第 2、3 页：返回和标题。选好了回到商户、账户
struct HeaderLeading: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        if state.chosen == nil, let back = state.screen.back {
            Button(intent: ShowLiveCategoryPageIntent(recordID: state.recordID, page: back)) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                    if let title = state.screen.title {
                        Text(title).lineLimit(1)
                    }
                }
                .font(.headline)
                .frame(minWidth: IslandLayout.header, minHeight: IslandLayout.header, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.merchant ?? state.account)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if state.merchant != nil {
                    Text(state.account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: IslandLayout.header, alignment: .leading)
        }
    }
}

struct AmountText: View {
    let amount: String

    var body: some View {
        Text(amount)
            .font(.headline)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// 按钮；选好了显示选中的分类
struct PickerBody: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        if let chosen = state.chosen {
            Label {
                Text(chosen.name).lineLimit(1)
            } icon: {
                Image(systemName: chosen.symbol)
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: IslandLayout.cell.height)
        } else {
            CellGrid(recordID: state.recordID, cells: state.screen.cells)
        }
    }
}

/// 一行 6 个；不满一行的靠左，整块居中
struct CellGrid: View {
    let recordID: String
    let cells: [LiveCategoryPicker.Cell]

    private var rows: [[LiveCategoryPicker.Cell]] {
        stride(from: 0, to: cells.count, by: LiveCategoryPicker.perRow).map {
            Array(cells[$0..<min($0 + LiveCategoryPicker.perRow, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.spacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: IslandLayout.spacing) {
                    ForEach(0..<rows[row].count, id: \.self) { index in
                        CellButton(recordID: recordID, cell: rows[row][index])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct CellButton: View {
    let recordID: String
    let cell: LiveCategoryPicker.Cell

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
                .font(.title3)
                .frame(height: 22)
            Text(cell.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 2)
        .frame(width: IslandLayout.cell.width, height: IslandLayout.cell.height)
        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 锁屏卡片：同样的三页。高 8 + 44 + 4 + 96 + 8 = 160，不超过上限
struct LockScreenCard: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: IslandLayout.spacing) {
            HStack {
                HeaderLeading(state: state)
                Spacer(minLength: 8)
                AmountText(amount: state.amount)
            }
            PickerBody(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
