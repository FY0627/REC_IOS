import SwiftUI
import UIKit
import UniformTypeIdentifiers
import BKModel

/// 选分类：大类排成格子，点一下就选上；有小类的大类名称旁有个小箭头，点它也先选上大类，同时在下面展开小类
/// （第一格是「不细分」，就记在大类上）。待分类、编辑流水、手动记一笔共用。
///
/// 放在列表的一个分组里：大类格子是一行，展开的小类是下一行（中间是列表的分隔线）。
/// 展开时是分组的框往下变大、多出一行，大类那一行不变，图标不会重新排一遍。
/// 任何时候只有一个分类是选中的样子（选中的是小类时，它所在的大类也是选中的样子）。
/// 格子不用懒加载的网格：放在列表的一行里时，懒加载会在行高变化时重新摆放，图标上下跳一下。
///
/// 「我的 › 分类」也用它（`arrangement` 不为 nil）：点一下打开这个分类，有小类的先展开，
/// 展开那一行第一格是大类自己。两行最后一格是「添加」（`add`）。
/// 长按弹出系统的菜单（删除）；接着拖动就是系统的拖放：排顺序，其他图标让位；小类拖到上面的大类上，放下就挪进那个大类。
struct CategoryGrid: View {
    let type: CategoryType
    var selected: String?
    /// 打开时选中的是大类，也展开它的小类
    var expandsSelected = false
    /// 「我的 › 分类」：排顺序、换大类；nil 是选分类
    var arrangement: CategoryArrangement?
    /// 「我的 › 分类」：格子最后的「添加」，参数是要加到哪个大类下面（nil 是加大类）；nil 时没有这一格
    var add: ((String?) -> Void)?
    /// 选分类时是选上；「我的 › 分类」里是打开这个分类
    let pick: (String) -> Void

    @Environment(LedgerStore.self) private var store
    @State private var expanded: String?

    static let columns = CategoryGridLayout.columns

    private struct Cell: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var hasChildren = false
    }

    /// 拖动的那一层：大类（`parentID` 为 nil），或某个大类的小类
    private struct Level {
        let parentID: String?
        /// 这一层现在的顺序
        let ids: [String]
        /// 能放小类的大类：小类拖到大类上时用
        let holders: Set<String>
    }

    var body: some View {
        let tree = store.categoryTree
        let nodes = arranged(tree.nodes(type), key: CategoryArrangement.topKey(type))
        let selectedTop = tree.topLevel(selected)?.id
        let tops = nodes.map(\.id)
        let holders = Set(nodes.filter { !$0.category.locked }.map(\.id))
        let addsTop = add != nil && type != .transfer
        let topLevel = Level(parentID: nil, ids: tops, holders: holders)
        // 「我的 › 分类」：能放小类的大类没有小类也能展开，展开那一行有「添加」
        let topCells = nodes.map {
            Cell(
                id: $0.id, name: $0.category.localizedName, symbol: $0.category.symbol,
                hasChildren: !$0.children.isEmpty || (add != nil && holders.contains($0.id))
            )
        }
        grid(topCells, adding: addsTop ? { add?(nil) } : nil) { cell in
            if arrangement == nil {
                button(cell, isSelected: selectedTop == cell.id) { tap(cell, selectedTop: selectedTop) }
            } else {
                arrangedCell(cell, level: topLevel, row: .top, isSelected: expanded == cell.id) { openOrExpand(cell) }
            }
        }
        .modifier(GridDrop(enabled: arrangement != nil, perform: finishDrop))
        .padding(.vertical, 6)
        // 和下面小类那一行之间的分隔线从格子的左边开始
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .onAppear {
            // 选中的是小类：把它所在的大类展开
            if let category = tree.category(selected), let parent = category.parentID {
                expanded = parent
            } else if expandsSelected, nodes.contains(where: { $0.id == selected && !$0.children.isEmpty }) {
                expanded = selected
            }
        }
        .onChange(of: selected) { _, id in
            // 在上面的「建议」里选了小类：也展开，下面看得出选的是哪个
            if let parent = tree.category(id)?.parentID, parent != expanded {
                withAnimation(.snappy(duration: 0.3)) { expanded = parent }
            }
        }
        if let node = nodes.first(where: { $0.id == expanded }) {
            let children = arranged(node.children, key: node.id).filter { $0.id != arrangement?.leaving }
            let addsChild = add != nil && holders.contains(node.id)
            let childLevel = Level(parentID: node.id, ids: children.map(\.id), holders: holders)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("\(node.category.localizedName)的小类")).font(.footnote).foregroundStyle(.secondary)
                let first = Cell(id: node.id, name: arrangement == nil ? L("不细分") : node.category.localizedName, symbol: node.category.symbol)
                let cells = [first] + children.map { Cell(id: $0.id, name: $0.localizedName, symbol: $0.symbol) }
                grid(cells, adding: addsChild ? { add?(node.id) } : nil) { cell in
                    if arrangement == nil {
                        button(cell, isSelected: selected == cell.id) {
                            withAnimation(.snappy(duration: 0.25)) { pick(cell.id) }
                        }
                    } else if cell.id == node.id {
                        // 第一格是大类自己：打开它，不能拖；小类拖到这一格上是排到最前面
                        arrangedCell(cell, level: nil, row: .children(node.id), isSelected: false) { pick(cell.id) }
                    } else {
                        arrangedCell(cell, level: childLevel, row: .children(node.id), isSelected: false) { pick(cell.id) }
                    }
                }
                .modifier(GridDrop(enabled: arrangement != nil, perform: finishDrop))
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

    /// 「我的 › 分类」点大类：有小类或能加小类的展开，再点收起；系统分类没有小类，直接打开
    private func openOrExpand(_ cell: Cell) {
        if cell.hasChildren {
            withAnimation(.snappy(duration: 0.3)) { expanded = expanded == cell.id ? nil : cell.id }
        } else {
            pick(cell.id)
        }
    }

    private func grid<Content: View>(
        _ cells: [Cell], adding: (() -> Void)? = nil, @ViewBuilder content: @escaping (Cell) -> Content
    ) -> some View {
        CategoryGridLayout {
            ForEach(cells) { cell in content(cell) }
            if let adding {
                Button(action: adding) { AddCategoryCell() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("添加"))
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

    // MARK: 「我的 › 分类」长按菜单、拖动

    /// 一格在哪一行：拖进来时按这个决定是让位还是挪进大类
    private enum Row {
        case top
        /// 某个大类展开的那一行
        case children(String)
    }

    /// 拖动中、刚放下还没存好时，按拖出来的顺序摆；别的时候是账本里的顺序
    private func arranged<Item: Identifiable>(_ items: [Item], key: String) -> [Item] where Item.ID == String {
        guard let order = arrangement?.order(key) else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// 能长按的一格（`level` 为 nil 时只能点）：长按弹出系统菜单，接着拖动是系统的拖放。每一格也是放下的地方
    @ViewBuilder
    private func arrangedCell(_ cell: Cell, level: Level?, row: Row, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let target = arrangement?.drag?.target
        let face = CategoryCell(
            name: cell.name, symbol: cell.symbol, isSelected: isSelected || target == cell.id,
            hasChildren: cell.hasChildren, expanded: expanded == cell.id
        )
        .scaleEffect(target == cell.id ? 1.12 : 1)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.name)
        .accessibilityHint(Text(cell.hasChildren ? "展开小类" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .onDrop(of: [.text], delegate: CategoryDrop(
            enter: { hover(cell.id, row: row, entered: true) },
            exit: { hover(cell.id, row: row, entered: false) },
            perform: finishDrop
        ))
        if let level {
            face
                .modifier(DeleteMenu(category: store.categoryTree.category(cell.id), tree: store.categoryTree) { delete(cell.id) })
                .onDrag { pickUp(cell.id, level: level) }
        } else {
            face
        }
    }

    /// 系统开始拖动：记下拖的是哪一格、这一层原来的顺序。上一次拖完没放在格子上（拖出去取消了）的顺序先存掉
    private func pickUp(_ id: String, level: Level) -> NSItemProvider {
        if let arrangement {
            arrangement.settleLingering(store: store)
            arrangement.drag = CategoryArrangement.Drag(
                id: id, key: level.parentID ?? CategoryArrangement.topKey(type), parentID: level.parentID,
                order: level.ids, original: level.ids, holders: level.holders
            )
        }
        return NSItemProvider(object: id as NSString)
    }

    /// 拖到一格上：大类在大类里让位；小类在自己那一行里让位，拖到上面能放小类的大类上时那个大类变大，放下就挪进去
    private func hover(_ cellID: String, row: Row, entered: Bool) {
        guard let arrangement, var drag = arrangement.drag else { return }
        switch row {
        case .top:
            if drag.parentID == nil {
                guard entered, let index = drag.order.firstIndex(of: cellID) else { return }
                drag.move(to: index)
            } else if entered {
                guard cellID != drag.parentID, drag.holders.contains(cellID) else { return }
                drag.target = cellID
            } else if drag.target == cellID {
                drag.target = nil
            }
        case .children(let parent):
            guard entered, drag.parentID == parent else { return }
            // 第一格是大类自己：排到最前面
            guard let index = cellID == parent ? 0 : drag.order.firstIndex(of: cellID) else { return }
            drag.target = nil
            drag.move(to: index)
        }
        guard let before = arrangement.drag, drag != before else { return }
        // 让一次位轻震一下；悬到能放的大类上再震一下
        if drag.order != before.order {
            arrangement.feedback(.move)
        } else if drag.target != nil, drag.target != before.target {
            arrangement.feedback(.target)
        }
        withAnimation(.snappy(duration: 0.25)) { arrangement.drag = drag }
    }

    /// 放下：拖到大类上的小类挪进去，其他的按拖出来的顺序存进账本
    private func finishDrop() -> Bool {
        guard let arrangement, let drag = arrangement.drag else { return false }
        arrangement.feedback(.drop)
        guard let target = drag.target else {
            arrangement.save(drag, store: store)
            arrangement.drag = nil
            return true
        }
        withAnimation(.snappy(duration: 0.3)) {
            arrangement.leaving = drag.id
            arrangement.drag = nil
        }
        Task {
            let moved = await arrangement.run { try await store.moveCategory(id: drag.id, toParent: target) }
            arrangement.leaving = nil
            // 展开挪去的大类：看得到它排在最后
            if moved { withAnimation(.snappy(duration: 0.3)) { expanded = target } }
        }
        return true
    }

    /// 记录不删，回到待分类；大类连小类一起删
    private func delete(_ id: String) {
        guard let arrangement else { return }
        Task { await arrangement.run { try await store.deleteCategory(id: id, moveRecordsTo: nil) } }
    }
}

/// 长按的系统菜单：删除。系统分类（自动记账要用）不能删，不弹菜单，长按直接拖
private struct DeleteMenu: ViewModifier {
    let category: LedgerCategory?
    let tree: CategoryTree
    let delete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let category, !category.locked {
            let title: LocalizedStringKey = tree.all.contains { $0.parentID == category.id } ? "连小类一起删除" : "删除"
            content.contextMenu {
                Button(role: .destructive, action: delete) {
                    Label(title, systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}

/// 一格（或整块格子）是放下的地方：拖进来、拖出去、放下。显示成「移动」，不是带加号的「拷贝」
private struct CategoryDrop: DropDelegate {
    var enter: () -> Void = {}
    var exit: () -> Void = {}
    let perform: () -> Bool

    func dropEntered(info: DropInfo) { enter() }
    func dropExited(info: DropInfo) { exit() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { perform() }
}

/// 格子之间的空隙、「添加」那一格上放下也算放下（不然拖动的顺序留着没存）
private struct GridDrop: ViewModifier {
    let enabled: Bool
    let perform: () -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.text], delegate: CategoryDrop(perform: perform))
        } else {
            content
        }
    }
}

/// 分类格子的排法：每行 4 格、格子一样宽，最后一行不满时空着；行高是这一行最高的格子，格子靠上。
/// 全部格子放在一个容器里：拖动排序时换行的格子也是滑过去，不是消失再出现
struct CategoryGridLayout: Layout {
    static let columns = 4
    static let spacing: CGFloat = 6
    static let lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let heights = lineHeights(subviews, cellWidth: Self.cellWidth(width))
        return CGSize(width: width, height: heights.reduce(0, +) + Self.lineSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = Self.cellWidth(bounds.width)
        var y = bounds.minY
        for (line, height) in lineHeights(subviews, cellWidth: width).enumerated() {
            for column in 0..<Self.columns {
                let index = line * Self.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (width + Self.spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height)
                )
            }
            y += height + Self.lineSpacing
        }
    }

    private func lineHeights(_ subviews: Subviews, cellWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: Self.columns).map { start in
            (start..<min(start + Self.columns, subviews.count))
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
                .max() ?? 0
        }
    }

    static func cellWidth(_ total: CGFloat) -> CGFloat {
        max((total - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
    }
}

/// 「我的 › 分类」拖动的状态。分类页持有，格子读写
@MainActor
@Observable
final class CategoryArrangement {
    struct Drag: Equatable {
        let id: String
        /// 存顺序用的键：`topKey` 或所在大类的 id
        let key: String
        /// 小类所在的大类；大类是 nil
        let parentID: String?
        /// 这一层的顺序，拖动中跟着变
        var order: [String]
        let original: [String]
        /// 能放小类的大类（系统分类不能）
        let holders: Set<String>
        /// 小类悬在哪个大类上：放下就挪进去
        var target: String?

        mutating func move(to index: Int) {
            guard let from = order.firstIndex(of: id), from != index, order.indices.contains(index) else { return }
            order.remove(at: from)
            order.insert(id, at: index)
        }
    }

    /// 正在拖的。系统的拖放没有「拖完了」的回调：没放在格子上（拖出去取消了）时留着，下次拖或离开页面时存掉
    var drag: Drag?
    /// 放下后、存好之前的顺序：免得先跳回原样再跳过去
    var pending: [String: [String]] = [:]
    /// 挪去别的大类的小类：存好之前不在原来那一行
    var leaving: String?
    var failure: String?

    /// 震动：让位、悬到能放的大类上、放下（拖起来时系统自己震）
    enum Feedback {
        case move, target, drop
    }

    @ObservationIgnored private var tickHaptic = UISelectionFeedbackGenerator()
    @ObservationIgnored private var lightHaptic = UIImpactFeedbackGenerator(style: .light)

    func feedback(_ kind: Feedback) {
        switch kind {
        case .move:
            tickHaptic.selectionChanged()
            tickHaptic.prepare()
        case .target:
            lightHaptic.impactOccurred()
            lightHaptic.prepare()
        case .drop:
            lightHaptic.impactOccurred()
        }
    }

    static func topKey(_ type: CategoryType) -> String { "top." + type.rawValue }

    func order(_ key: String) -> [String]? {
        drag?.key == key ? drag?.order : pending[key]
    }

    /// 顺序变了就存进账本；存好之前按拖出来的顺序摆
    func save(_ drag: Drag, store: LedgerStore) {
        guard drag.order != drag.original else { return }
        pending[drag.key] = drag.order
        Task {
            await run { try await store.reorderCategories(drag.order) }
            pending[drag.key] = nil
        }
    }

    /// 上一次拖完没放在格子上：只存顺序，不挪大类（悬在大类上就取消了的不算放下）
    func settleLingering(store: LedgerStore) {
        guard let drag else { return }
        self.drag = nil
        save(drag, store: store)
    }

    @discardableResult
    func run(_ action: () async throws -> Void) async -> Bool {
        do {
            try await action()
            failure = nil
            return true
        } catch {
            failure = L("操作失败：\(error.localizedDescription)")
            return false
        }
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
                    CategoryCell(name: category.localizedName, symbol: category.symbol, isSelected: selected == category.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.localizedName)
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

/// 「我的 › 分类」格子最后一格：添加大类或小类
private struct AddCategoryCell: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.06), in: Circle())
            Text("添加")
                .font(.caption)
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 选图标：放在分类编辑页里，点一下就换
struct SymbolGrid: View {
    @Binding var symbol: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 12) {
            ForEach(CategorySymbols.all, id: \.self) { name in
                Button {
                    symbol = name
                } label: {
                    Image(systemName: name)
                        .font(.title3)
                        .foregroundStyle(symbol == name ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                        .frame(width: 48, height: 48)
                        .background(symbol == name ? AnyShapeStyle(TintShapeStyle().opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(symbol == name ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 6)
    }
}
