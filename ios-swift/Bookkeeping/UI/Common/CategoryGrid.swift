import SwiftUI
import UIKit
import BKModel

/// 选分类：大类排成格子，点一下就选上；有小类的大类名称旁有个小箭头，点它也先选上大类，同时在下面展开小类
/// （第一格是「不细分」，就记在大类上）。待分类、编辑流水、手动记一笔共用。隐藏的分类不出现。
///
/// 放在列表的一个分组里：大类格子是一行，展开的小类是下一行（中间是列表的分隔线）。
/// 展开时是分组的框往下变大、多出一行，大类那一行不变，图标不会重新排一遍。
/// 任何时候只有一个分类是选中的样子（选中的是小类时，它所在的大类也是选中的样子）。
/// 格子不用懒加载的网格：放在列表的一行里时，懒加载会在行高变化时重新摆放，图标上下跳一下。
///
/// 「我的 › 分类」也用它（`arrangement` 不为 nil）：隐藏的也排出来（淡一些）。点一下打开这个分类，有小类的先展开，
/// 展开那一行第一格是大类自己。长按拖动排顺序，其他图标让位；小类拖到上面的大类上，放下就挪进那个大类。
struct CategoryGrid: View {
    let type: CategoryType
    var selected: String?
    /// 打开时选中的是大类，也展开它的小类
    var expandsSelected = false
    /// 「我的 › 分类」：排顺序、换大类；nil 是选分类
    var arrangement: CategoryArrangement?
    /// 选分类时是选上；「我的 › 分类」里是打开这个分类
    let pick: (String) -> Void

    @Environment(LedgerStore.self) private var store
    @State private var expanded: String?
    /// 手指按在能拖的格子上；松手或被打断时回到 false，拖起来了就这时放下
    @GestureState private var touching = false

    static let columns = CategoryGridLayout.columns

    private struct Cell: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var hasChildren = false
        var hidden = false
    }

    /// 拖动的那一层：大类（`parentID` 为 nil），或某个大类的小类
    private struct Level {
        let parentID: String?
        /// 这一层现在的顺序
        let ids: [String]
        /// 大类现在的顺序、能放小类的大类：小类拖到大类上时用
        let tops: [String]
        let holders: Set<String>
    }

    var body: some View {
        let tree = store.categoryTree
        let nodes = arranged(tree.nodes(type, includeHidden: arrangement != nil), key: CategoryArrangement.topKey(type))
        let selectedTop = tree.topLevel(selected)?.id
        let tops = nodes.map(\.id)
        let holders = Set(nodes.filter { !$0.category.locked }.map(\.id))
        let topLevel = Level(parentID: nil, ids: tops, tops: tops, holders: holders)
        let topCells = nodes.map {
            Cell(id: $0.id, name: $0.category.localizedName, symbol: $0.category.symbol, hasChildren: !$0.children.isEmpty, hidden: $0.category.hidden)
        }
        grid(topCells) { cell in
            if arrangement == nil {
                button(cell, isSelected: selectedTop == cell.id) { tap(cell, selectedTop: selectedTop) }
            } else {
                arrangedCell(cell, level: topLevel, isSelected: expanded == cell.id) { openOrExpand(cell) }
            }
        }
        .modifier(frameReporter(children: false))
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
        .onChange(of: touching) { _, now in
            if !now { drop() }
        }
        if let node = nodes.first(where: { $0.id == expanded }) {
            let children = arranged(node.children, key: node.id).filter { $0.id != arrangement?.leaving }
            let childLevel = Level(parentID: node.id, ids: children.map(\.id), tops: tops, holders: holders)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("\(node.category.localizedName)的小类")).font(.footnote).foregroundStyle(.secondary)
                let first = Cell(id: node.id, name: arrangement == nil ? L("不细分") : node.category.localizedName, symbol: node.category.symbol, hidden: node.category.hidden)
                let cells = [first] + children.map { Cell(id: $0.id, name: $0.localizedName, symbol: $0.symbol, hidden: $0.hidden) }
                grid(cells) { cell in
                    if arrangement == nil {
                        button(cell, isSelected: selected == cell.id) {
                            withAnimation(.snappy(duration: 0.25)) { pick(cell.id) }
                        }
                    } else if cell.id == node.id {
                        // 第一格是大类自己：打开它，不能拖
                        arrangedCell(cell, level: nil, isSelected: false) { pick(cell.id) }
                    } else {
                        arrangedCell(cell, level: childLevel, isSelected: false) { pick(cell.id) }
                    }
                }
                .modifier(frameReporter(children: true))
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

    /// 「我的 › 分类」点大类：有小类的展开，再点收起；没有小类的打开这个分类
    private func openOrExpand(_ cell: Cell) {
        if cell.hasChildren {
            withAnimation(.snappy(duration: 0.3)) { expanded = expanded == cell.id ? nil : cell.id }
        } else {
            pick(cell.id)
        }
    }

    private func grid<Content: View>(_ cells: [Cell], @ViewBuilder content: @escaping (Cell) -> Content) -> some View {
        CategoryGridLayout {
            ForEach(cells) { cell in content(cell) }
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

    // MARK: 「我的 › 分类」长按拖动

    /// 拖动中、刚放下还没存好时，按拖出来的顺序摆；别的时候是账本里的顺序
    private func arranged<Item: Identifiable>(_ items: [Item], key: String) -> [Item] where Item.ID == String {
        guard let order = arrangement?.order(key) else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// 能长按拖动的一格（`level` 为 nil 时只能点）。拖起来的那一格原地空着，浮起来的图标由 `CategoryDragOverlay` 画
    @ViewBuilder
    private func arrangedCell(_ cell: Cell, level: Level?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let lift = arrangement?.lift
        let face = CategoryCell(
            name: cell.name, symbol: cell.symbol, isSelected: isSelected || lift?.target == cell.id,
            hasChildren: cell.hasChildren, expanded: expanded == cell.id, dimmed: cell.hidden
        )
        .scaleEffect(lift?.target == cell.id ? 1.12 : 1)
        .opacity(lift?.id == cell.id ? 0 : 1)
        // 拖起来的那一格看不见了也还按得着：手势接着走
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.name)
        .accessibilityHint(Text(cell.hasChildren ? "展开小类" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        if let level {
            // 点一下、长按到时间浮起来、跟着手指走是三个手势：长按和点一下互斥，跟手指的一直同时在跑，
            // 不和长按串成一个（串起来时手指一按下就算开始，点一下永远轮不到）
            face
                .onTapGesture(perform: action)
                .onLongPressGesture(minimumDuration: 0.3) { pickUp(cell.id, level: level) }
                .simultaneousGesture(followGesture(cell.id))
        } else {
            face.onTapGesture(perform: action)
        }
    }

    /// 手指按下就开始跟：还没浮起来时什么也不做，浮起来后让位、找目标
    private func followGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { follow(id, $0) }
    }

    private func pickUp(_ id: String, level: Level) {
        // 已经松手了就不浮起来：没有下一次松手来放下它
        guard touching, let arrangement, arrangement.lift == nil, let category = store.categoryTree.category(id),
              let index = level.ids.firstIndex(of: id) else { return }
        // 小类那一行第一格是大类自己
        let offset = level.parentID == nil ? 0 : 1
        let frame = level.parentID == nil ? arrangement.topFrame : arrangement.childFrame
        arrangement.begin(
            CategoryArrangement.Lift(
                id: id, name: category.localizedName, symbol: category.symbol, hidden: category.hidden,
                key: level.parentID ?? CategoryArrangement.topKey(type), parentID: level.parentID,
                order: level.ids, original: level.ids, tops: level.tops, holders: level.holders,
                width: CategoryGridLayout.cellWidth(frame.width)
            ),
            at: CategoryGridLayout.center(of: index + offset, count: level.ids.count + offset, in: frame)
        )
    }

    /// 大类在大类里让位；小类在自己那一行里让位，拖到上面的大类上时那个大类变大，放下就挪进去
    private func follow(_ id: String, _ drag: DragGesture.Value) {
        guard let arrangement, var lift = arrangement.lift, lift.id == id, arrangement.settling == nil else { return }
        arrangement.follow(drag.location, start: drag.startLocation)
        let point = drag.location
        if lift.parentID == nil {
            if let slot = CategoryGridLayout.slot(at: point, count: lift.order.count, in: arrangement.topFrame) {
                lift.move(to: min(slot, lift.order.count - 1))
            }
        } else if let slot = CategoryGridLayout.slot(at: point, count: lift.order.count + 1, in: arrangement.childFrame) {
            lift.target = nil
            lift.move(to: min(max(slot - 1, 0), lift.order.count - 1))
        } else if let slot = CategoryGridLayout.slot(at: point, count: lift.tops.count, in: arrangement.topFrame),
                  slot < lift.tops.count, lift.tops[slot] != lift.parentID, lift.holders.contains(lift.tops[slot]) {
            lift.target = lift.tops[slot]
        } else {
            lift.target = nil
        }
        guard let before = arrangement.lift, lift != before else { return }
        // 让一次位轻震一下；悬到能放的大类上再震一下
        if lift.order != before.order {
            arrangement.feedback(.move)
        } else if let target = lift.target, target != before.target {
            arrangement.feedback(.target)
        }
        withAnimation(.snappy(duration: 0.25)) { arrangement.lift = lift }
    }

    /// 松手：浮起来的图标先回到格子（或缩进拖到的大类），再存进账本
    private func drop() {
        guard let arrangement, let lift = arrangement.lift, arrangement.settling == nil else { return }
        arrangement.feedback(.drop)
        if let target = lift.target, let index = lift.tops.firstIndex(of: target) {
            withAnimation(.snappy(duration: 0.2)) {
                arrangement.settle(at: CategoryGridLayout.center(of: index, count: lift.tops.count, in: arrangement.topFrame), into: true)
            }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.snappy(duration: 0.3)) {
                    arrangement.leaving = lift.id
                    arrangement.finish()
                }
                let moved = await arrangement.run { try await store.moveCategory(id: lift.id, toParent: target) }
                arrangement.leaving = nil
                // 展开挪去的大类：看得到它排在最后
                if moved { withAnimation(.snappy(duration: 0.3)) { expanded = target } }
            }
        } else {
            let offset = lift.parentID == nil ? 0 : 1
            let frame = lift.parentID == nil ? arrangement.topFrame : arrangement.childFrame
            let index = (lift.order.firstIndex(of: lift.id) ?? 0) + offset
            withAnimation(.snappy(duration: 0.2)) {
                arrangement.settle(at: CategoryGridLayout.center(of: index, count: lift.order.count + offset, in: frame), into: false)
            }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                let changed = lift.order != lift.original
                if changed { arrangement.pending[lift.key] = lift.order }
                arrangement.finish()
                guard changed else { return }
                await arrangement.run { try await store.reorderCategories(lift.order) }
                arrangement.pending[lift.key] = nil
            }
        }
    }

    /// 「我的 › 分类」量两块格子在屏幕上的位置（手指在第几格按它算）；选分类时不量
    private func frameReporter(children: Bool) -> GridFrame {
        guard let arrangement else { return GridFrame(report: nil) }
        return GridFrame(report: { (frame: CGRect) in
            if children {
                arrangement.childFrame = frame
            } else {
                arrangement.topFrame = frame
            }
        })
    }
}

private struct GridFrame: ViewModifier {
    let report: ((CGRect) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let report {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
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

    /// 手指落在第几格（那一格有没有图标都算）；不在这块格子里是 nil。
    /// 格子一样高，按位置算，不看图标现在动画到哪：让位时图标从手指下滑过也不会来回换
    static func slot(at point: CGPoint, count: Int, in frame: CGRect) -> Int? {
        guard count > 0, frame.width > 0, frame.contains(point) else { return nil }
        let lines = (count + columns - 1) / columns
        let height = (frame.height - lineSpacing * CGFloat(lines - 1)) / CGFloat(lines)
        let column = min(max(Int((point.x - frame.minX) / (cellWidth(frame.width) + spacing)), 0), columns - 1)
        let line = min(max(Int((point.y - frame.minY) / (height + lineSpacing)), 0), lines - 1)
        return line * columns + column
    }

    /// 第几格的中心
    static func center(of index: Int, count: Int, in frame: CGRect) -> CGPoint {
        let lines = max((count + columns - 1) / columns, 1)
        let width = cellWidth(frame.width)
        let height = (frame.height - lineSpacing * CGFloat(lines - 1)) / CGFloat(lines)
        return CGPoint(
            x: frame.minX + CGFloat(index % columns) * (width + spacing) + width / 2,
            y: frame.minY + CGFloat(index / columns) * (height + lineSpacing) + height / 2
        )
    }
}

/// 「我的 › 分类」长按拖动的状态。分类页持有；格子写，浮起来的图标读。
/// 手指位置只有浮起来的图标读：拖动时格子和列表不跟着每一下重画，只在让位、换目标、放下时重画
@MainActor
@Observable
final class CategoryArrangement {
    struct Lift: Equatable {
        let id: String
        let name: String
        let symbol: String
        let hidden: Bool
        /// 存顺序用的键：`topKey` 或所在大类的 id
        let key: String
        /// 小类所在的大类；大类是 nil
        let parentID: String?
        /// 这一层的顺序，拖动中跟着变
        var order: [String]
        let original: [String]
        /// 大类的顺序、能放小类的大类（系统分类不能）
        let tops: [String]
        let holders: Set<String>
        /// 格子宽度：浮起来的图标和格子里的一样宽
        let width: CGFloat
        /// 小类悬在哪个大类上：放下就挪进去
        var target: String?

        mutating func move(to index: Int) {
            guard let from = order.firstIndex(of: id), from != index, order.indices.contains(index) else { return }
            order.remove(at: from)
            order.insert(id, at: index)
        }
    }

    enum Settling {
        /// 回到格子
        case back
        /// 缩进拖到的大类
        case into
    }

    var lift: Lift?
    /// 拖起来到放好之间：列表不滚动
    private(set) var active = false
    private(set) var settling: Settling?
    /// 手指的位置（屏幕坐标），按住的地方离图标中心多远
    private(set) var location: CGPoint = .zero
    private(set) var grab: CGSize = .zero
    /// 放下后、存好之前的顺序：免得先跳回原样再跳过去
    var pending: [String: [String]] = [:]
    /// 挪去别的大类的小类：存好之前不在原来那一行
    var leaving: String?
    var failure: String?

    @ObservationIgnored private var grabbed = false
    /// 大类、小类两块格子在屏幕上的位置。滚动时一直在变，不触发重画
    @ObservationIgnored var topFrame: CGRect = .zero
    @ObservationIgnored var childFrame: CGRect = .zero

    /// 震动：浮起来、让位、悬到能放的大类上、放下
    enum Feedback {
        case lift, move, target, drop
    }

    @ObservationIgnored private var liftHaptic = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private var tickHaptic = UISelectionFeedbackGenerator()
    @ObservationIgnored private var lightHaptic = UIImpactFeedbackGenerator(style: .light)

    func feedback(_ kind: Feedback) {
        switch kind {
        case .lift:
            liftHaptic.impactOccurred()
            tickHaptic.prepare()
            lightHaptic.prepare()
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
        lift?.key == key ? lift?.order : pending[key]
    }

    func begin(_ lift: Lift, at center: CGPoint) {
        guard self.lift == nil else { return }
        location = center
        grab = .zero
        grabbed = false
        settling = nil
        self.lift = lift
        active = true
        feedback(.lift)
    }

    func follow(_ point: CGPoint, start: CGPoint) {
        if !grabbed {
            grabbed = true
            grab = CGSize(width: start.x - location.x, height: start.y - location.y)
        }
        location = point
    }

    func settle(at center: CGPoint, into: Bool) {
        settling = into ? .into : .back
        location = center
        grab = .zero
    }

    func finish() {
        lift = nil
        settling = nil
        active = false
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

/// 长按拖动时浮起来的图标，跟着手指走。盖在整个分类页的列表上：从小类那一行拖到大类那一行也不会被挡住
struct CategoryDragOverlay: View {
    let arrangement: CategoryArrangement

    var body: some View {
        GeometryReader { proxy in
            if let lift = arrangement.lift {
                let origin = proxy.frame(in: .global).origin
                CategoryCell(name: lift.name, symbol: lift.symbol, isSelected: false, dimmed: lift.hidden)
                    .frame(width: lift.width)
                    .scaleEffect(arrangement.settling == .into ? 0.5 : (arrangement.settling == .back ? 1 : 1.15))
                    .opacity(arrangement.settling == .into ? 0 : 1)
                    .position(
                        x: arrangement.location.x - arrangement.grab.width - origin.x,
                        y: arrangement.location.y - arrangement.grab.height - origin.y
                    )
            }
        }
        .allowsHitTesting(false)
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

/// 一个分类：圆形图标和名称；有小类的名称旁有个小箭头。隐藏的分类（只在「我的 › 分类」里出现）淡一些
private struct CategoryCell: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    var hasChildren = false
    var expanded = false
    var dimmed = false

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
        .opacity(dimmed ? 0.4 : 1)
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
