import AppIntents
import SwiftUI
import BKModel

/// 摘要卡片的样子（ADR 0027）：底是系统给的（浅色、深色跟着系统），字用系统的主要、次要颜色，按钮的圆用主题色。
///
/// - 顶上一行：第 1 页是商户（没有商户是账户）、下面一行账户，右边金额；第 2、3 页是返回和标题；
/// - 按钮和灵动岛一样一行 5 个、三页（`LiveCategoryPicker`）：分类是主题色的圆，「全部」「更多」是灰色的圆，字在圆下面；
/// - 每一页都占两行按钮的高，第 1 页只有一行时上下居中，换页时卡片不变高；
/// - 选好了显示选中的分类。
/// 系统要求卡片不超过 400 点高：顶上 44 + 12 + 两行 120，字号最大到 xLarge
struct CategorySnippetView: View {
    let recordID: String
    let merchant: String?
    let account: String
    let amount: String
    /// 这一页；App 被重新拉起来、账本里也找不到这一笔时是 nil，只显示顶上一行
    let screen: LiveCategoryPicker.Screen?
    let chosen: LiveCategoryPicker.Option?
    let tint: Color

    private enum Layout {
        static let header: CGFloat = 44
        static let cell: CGFloat = 56
        static let circle: CGFloat = 36
        static let rowSpacing: CGFloat = 8
        static let columnSpacing: CGFloat = 4
        static var grid: CGFloat {
            let rows = CGFloat(LiveCategoryPicker.perScreen / LiveCategoryPicker.perRow)
            return cell * rows + rowSpacing * (rows - 1)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
                .frame(minHeight: Layout.header)
            Group {
                if let chosen {
                    chosenRow(chosen)
                } else if let screen {
                    grid(screen.cells)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Layout.grid, maxHeight: Layout.grid)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    // MARK: 顶上一行

    @ViewBuilder private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if chosen == nil, let screen, let back = screen.back {
                Button(intent: ShowSnippetPageIntent(recordID: recordID, page: back)) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                        if let title = screen.title {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: Layout.header, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(merchant ?? account)
                        .font(.headline)
                        .lineLimit(1)
                    if merchant != nil {
                        Text(account)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(amount)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: 按钮

    private func grid(_ cells: [LiveCategoryPicker.Cell]) -> some View {
        let perRow = LiveCategoryPicker.perRow
        let rows = stride(from: 0, to: cells.count, by: perRow).map { Array(cells[$0..<min($0 + perRow, cells.count)]) }
        return VStack(spacing: Layout.rowSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: Layout.columnSpacing) {
                    ForEach(0..<perRow, id: \.self) { column in
                        if column < rows[row].count {
                            cellButton(rows[row][column])
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: Layout.cell, maxHeight: Layout.cell)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cellButton(_ cell: LiveCategoryPicker.Cell) -> some View {
        switch cell.action {
        case .pick(let categoryID):
            Button(intent: PickSnippetCategoryIntent(recordID: recordID, categoryID: categoryID)) { cellLabel(cell) }
                .buttonStyle(.plain)
        case .show(let page):
            Button(intent: ShowSnippetPageIntent(recordID: recordID, page: page)) { cellLabel(cell) }
                .buttonStyle(.plain)
        }
    }

    private func cellLabel(_ cell: LiveCategoryPicker.Cell) -> some View {
        VStack(spacing: 4) {
            Image(systemName: cell.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(cell.isNavigation ? Color.primary : tint)
                .frame(width: Layout.circle, height: Layout.circle)
                .background(cell.isNavigation ? Color.secondary.opacity(0.15) : tint.opacity(0.18), in: Circle())
            Text(cell.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: Layout.cell, maxHeight: Layout.cell)
        .contentShape(Rectangle())
    }

    // MARK: 选好了

    private func chosenRow(_ chosen: LiveCategoryPicker.Option) -> some View {
        HStack(spacing: 10) {
            Image(systemName: chosen.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint, in: Circle())
            Text(chosen.name)
                .font(.headline)
                .lineLimit(1)
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
        }
    }
}
