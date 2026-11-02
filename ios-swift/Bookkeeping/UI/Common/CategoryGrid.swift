import SwiftUI
import BKModel

/// 选分类：大类排成格子，点一下就选上；有小类的大类名称旁有个小箭头，点它也先选上大类，同时在下面展开小类
/// （第一格是「不细分」，就记在大类上）。待分类、编辑流水、手动记一笔共用。隐藏的分类不出现。
///
/// 放在列表的一个分组里：大类格子是一行，展开的小类是下一行（中间是列表的分隔线）。
/// 展开时是分组的框往下变大、多出一行，大类那一行不变，图标不会重新排一遍。
/// 任何时候只有一个分类是选中的样子（选中的是小类时，它所在的大类也是选中的样子）。
/// 格子不用懒加载的网格：放在列表的一行里时，懒加载会在行高变化时重新摆放，图标上下跳一下。
struct CategoryGrid: View {
    let type: CategoryType
    var selected: String?
    let pick: (String) -> Void

    @Environment(LedgerStore.self) private var store
    @State private var expanded: String?

    static let columns = 4

    private struct Cell: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var hasChildren = false
    }

    var body: some View {
        let tree = store.categoryTree
        let nodes = tree.nodes(type)
        let selectedTop = tree.topLevel(selected)?.id
        rows(nodes.map { Cell(id: $0.id, name: $0.category.name, symbol: $0.category.symbol, hasChildren: !$0.children.isEmpty) }) { cell in
            button(cell, isSelected: selectedTop == cell.id) { tap(cell, selectedTop: selectedTop) }
        }
        .padding(.vertical, 6)
        // 和下面小类那一行之间的分隔线从格子的左边开始
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .onAppear {
            // 选中的是小类：把它所在的大类展开
            if let category = tree.category(selected), let parent = category.parentID { expanded = parent }
        }
        .onChange(of: selected) { _, id in
            // 在上面的「建议」里选了小类：也展开，下面看得出选的是哪个
            if let parent = tree.category(id)?.parentID, parent != expanded {
                withAnimation(.snappy(duration: 0.3)) { expanded = parent }
            }
        }
        if let node = nodes.first(where: { $0.id == expanded }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(node.category.name)的小类").font(.footnote).foregroundStyle(.secondary)
                let cells = [Cell(id: node.id, name: "不细分", symbol: node.category.symbol)]
                    + node.children.map { Cell(id: $0.id, name: $0.name, symbol: $0.symbol) }
                rows(cells) { cell in
                    button(cell, isSelected: selected == cell.id) {
                        withAnimation(.snappy(duration: 0.25)) { pick(cell.id) }
                    }
                }
            }
            .padding(.vertical, 6)
            // 换一个大类展开时，整行换掉（列表的删除 / 插入动画），不是在同一行里改内容
            .id(node.id)
        }
    }

    private func tap(_ cell: Cell, selectedTop: String?) {
        withAnimation(.snappy(duration: 0.3)) {
            if !cell.hasChildren {
                expanded = nil
                pick(cell.id)
            } else if expanded == cell.id {
                expanded = nil
            } else {
                expanded = cell.id
                // 先记在大类上；已经选了它的小类就不动
                if selectedTop != cell.id { pick(cell.id) }
            }
        }
    }

    /// 每行 4 格；最后一行不满时用空白补齐，格子宽度不变
    private func rows<Content: View>(_ cells: [Cell], content: @escaping (Cell) -> Content) -> some View {
        let lines = stride(from: 0, to: cells.count, by: Self.columns).map { Array(cells[$0..<min($0 + Self.columns, cells.count)]) }
        return VStack(spacing: 12) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(lines[index]) { cell in content(cell) }
                    ForEach(0..<(Self.columns - lines[index].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private func button(_ cell: Cell, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CategoryCell(name: cell.name, symbol: cell.symbol, isSelected: isSelected, hasChildren: cell.hasChildren, expanded: expanded == cell.id)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.name)
        .accessibilityHint(Text(cell.hasChildren ? "展开小类" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 这一笔最可能的几个分类，排成一行放在完整的格子上面。和下面的格子是同一个选择：点一下选上，可以换
struct SuggestedCategories: View {
    let categories: [LedgerCategory]
    var selected: String?
    let pick: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(categories) { category in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { pick(category.id) }
                } label: {
                    CategoryCell(name: category.name, symbol: category.symbol, isSelected: selected == category.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.name)
                .accessibilityAddTraits(selected == category.id ? [.isSelected] : [])
            }
            ForEach(0..<max(0, CategoryGrid.columns - categories.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .padding(.vertical, 6)
    }
}

/// 一个分类：圆形图标和名称；有小类的名称旁有个小箭头
private struct CategoryCell: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    var hasChildren = false
    var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                .frame(width: 48, height: 48)
                .background(isSelected ? AnyShapeStyle(TintShapeStyle().opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Circle())
            HStack(spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if hasChildren {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .font(.caption)
            .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 选图标
struct SymbolPicker: View {
    @Binding var symbol: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 12) {
                ForEach(CategorySymbols.all, id: \.self) { name in
                    Button {
                        symbol = name
                        dismiss()
                    } label: {
                        Image(systemName: name)
                            .font(.title3)
                            .foregroundStyle(symbol == name ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                            .frame(width: 48, height: 48)
                            .background(symbol == name ? AnyShapeStyle(TintShapeStyle().opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding()
        }
        .navigationTitle("选择图标")
        .navigationBarTitleDisplayMode(.inline)
    }
}
