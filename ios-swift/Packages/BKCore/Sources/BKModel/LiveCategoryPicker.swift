import Foundation

/// 灵动岛（实时活动）上选分类（ADR 0024）：三页，都在岛上点完，不打开 App。
///
/// - 第 1 页：5 个推荐（这个商户选过的、常选的在前，可以是小类）和「全部」；
/// - 第 2 页（点「全部」）：这个类型的全部大类，分类页的顺序，一页 12 格（每行 6 个、2 行），放不下时最后一格是「更多」；
/// - 第 3 页（点有小类的大类）：它的小类，最后一个是「只记<大类名>」。
///
/// 第 2、3 页左上角有返回。App 开启实时活动时算好一页（`screen`）放进实时活动的内容，换页时 App 再算下一页。
/// 扩展只照着显示，不需要翻译表：分类名称和固定的字由 App 按选的语言写进来（`localized`）
public struct LiveCategoryPicker: Hashable, Sendable, Codable {
    public typealias Option = NotificationPicker.Option
    public typealias Group = NotificationPicker.Group

    /// 第 1 页的一个推荐。`opens`：点了进它的小类——只有刚开始没记录、补位凑上的带小类的大类这样；
    /// 用户自己选过、常选的大类本身，点了直接记
    public struct Quick: Hashable, Sendable, Codable {
        public var option: Option
        public var opens: Bool

        public init(option: Option, opens: Bool) {
            self.option = option
            self.opens = opens
        }
    }

    /// 格子和标题上固定的字，按选的语言。`only` 里的 `%@` 换成大类名称
    public struct Labels: Hashable, Sendable, Codable {
        public var all: String
        public var more: String
        public var only: String
        /// 第 2 页的标题：「支出」「收入」
        public var type: String

        public init(all: String = "全部", more: String = "更多", only: String = "只记%@", type: String = "支出") {
            self.all = all
            self.more = more
            self.only = only
            self.type = type
        }
    }

    public enum Page: Hashable, Sendable, Codable {
        /// 第 1 页：推荐和「全部」
        case quick
        /// 第 2 页：大类的第几屏（超过 12 个时有「更多」）
        case parents(chunk: Int)
        /// 第 3 页：这个大类的小类的第几屏。`fromQuick`：从第 1 页的推荐点进来的，返回回到第 1 页
        case children(parentID: String, chunk: Int, fromQuick: Bool)
    }

    public struct Cell: Hashable, Sendable, Codable {
        public enum Action: Hashable, Sendable, Codable {
            /// 记到这个分类
            case pick(String)
            /// 换到这一页
            case show(Page)
        }

        public var title: String
        /// SF Symbols 图标名
        public var symbol: String
        public var action: Action

        public init(title: String, symbol: String, action: Action) {
            self.title = title
            self.symbol = symbol
            self.action = action
        }

        /// 「全部」「更多」：换到另一屏，不是一个分类（岛上画成白色的圆）。有小类的大类虽然也换页，但它是分类
        public var isNavigation: Bool {
            switch action {
            case .pick: false
            case .show(.quick), .show(.parents): true
            case .show(.children(_, let chunk, _)): chunk > 0
            }
        }
    }

    /// 岛上的一页：第 1 页没有标题和返回（顶上一行是商户、账户、金额）
    public struct Screen: Hashable, Sendable, Codable {
        public var page: Page
        public var title: String?
        public var back: Page?
        public var cells: [Cell]

        public init(page: Page, title: String?, back: Page?, cells: [Cell]) {
            self.page = page
            self.title = title
            self.back = back
            self.cells = cells
        }
    }

    /// 第 1 页几个推荐（加「全部」一共 6 格，一行）
    public static let quickCount = 5
    /// 一行几格
    public static let perRow = 6
    /// 一屏几格（2 行）
    public static let perScreen = 12

    public var quick: [Quick]
    /// 全部大类，分类页的顺序；小类也是分类页的顺序
    public var groups: [Group]
    public var labels: Labels

    public init(quick: [Quick], groups: [Group], labels: Labels = Labels()) {
        self.quick = Array(quick.prefix(Self.quickCount))
        self.groups = groups
        self.labels = labels
    }

    /// 从这笔的候选算（`CategoryLearner`）：推荐用 `quick`，大类、小类都换回分类页的顺序，固定不变。
    /// 补位凑上的带小类的大类（不在 `learnedIDs` 里）点了进小类
    public init(_ suggestions: CategorySuggestions, labels: Labels = Labels()) {
        let ordered = suggestions.groups.sorted { Self.order($0.parent, $1.parent) }
        let groups = ordered.map { group in
            Group(option: Option(group.parent), children: group.children.sorted(by: Self.order).map(Option.init))
        }
        let withChildren = Set(suggestions.groups.filter { !$0.children.isEmpty }.map(\.parent.id))
        let quick = suggestions.quick.map { category in
            Quick(option: Option(category), opens: withChildren.contains(category.id) && !suggestions.learnedIDs.contains(category.id))
        }
        self.init(quick: quick, groups: groups, labels: labels)
    }

    static func order(_ a: LedgerCategory, _ b: LedgerCategory) -> Bool {
        a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.id < b.id
    }

    // MARK: 一页

    public func screen(_ page: Page) -> Screen {
        switch page {
        case .quick:
            let cells = quick.map { item in
                Cell(
                    title: item.option.name, symbol: item.option.symbol,
                    action: item.opens && group(item.option.id) != nil
                        ? .show(.children(parentID: item.option.id, chunk: 0, fromQuick: true))
                        : .pick(item.option.id)
                )
            }
            return Screen(page: .quick, title: nil, back: nil, cells: cells + [Cell(title: labels.all, symbol: Self.allSymbol, action: .show(.parents(chunk: 0)))])

        case .parents(let requested):
            let items = groups.map { group in
                Cell(
                    title: group.option.name, symbol: group.option.symbol,
                    action: group.children.isEmpty ? .pick(group.option.id) : .show(.children(parentID: group.option.id, chunk: 0, fromQuick: false))
                )
            }
            let chunk = Self.clamp(requested, count: items.count)
            let cells = Self.chunk(items, chunk, more: more(.parents(chunk: chunk + 1)))
            return Screen(page: .parents(chunk: chunk), title: labels.type, back: chunk == 0 ? .quick : .parents(chunk: chunk - 1), cells: cells)

        case .children(let parentID, let requested, let fromQuick):
            guard let group = group(parentID) else { return screen(.parents(chunk: 0)) }
            let only = labels.only.replacingOccurrences(of: "%@", with: group.option.name)
            let items = group.children.map { Cell(title: $0.name, symbol: $0.symbol, action: .pick($0.id)) }
                + [Cell(title: only, symbol: group.option.symbol, action: .pick(group.option.id))]
            let chunk = Self.clamp(requested, count: items.count)
            let cells = Self.chunk(items, chunk, more: more(.children(parentID: parentID, chunk: chunk + 1, fromQuick: fromQuick)))
            let back: Page = chunk > 0
                ? .children(parentID: parentID, chunk: chunk - 1, fromQuick: fromQuick)
                : (fromQuick ? .quick : .parents(chunk: parentChunk(parentID)))
            return Screen(page: .children(parentID: parentID, chunk: chunk, fromQuick: fromQuick), title: group.option.name, back: back, cells: cells)
        }
    }

    /// 这个分类（小类、大类、推荐里的）：选中后岛上显示它
    public func option(_ id: String) -> Option? {
        if let item = quick.first(where: { $0.option.id == id }) { return item.option }
        for group in groups {
            if group.option.id == id { return group.option }
            if let child = group.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private func more(_ page: Page) -> Cell {
        Cell(title: labels.more, symbol: Self.moreSymbol, action: .show(page))
    }

    private func group(_ id: String) -> Group? {
        groups.first { $0.option.id == id }
    }

    /// 这个大类在第 2 页的第几屏（从小类返回时回到它）
    private func parentChunk(_ id: String) -> Int {
        guard let index = groups.firstIndex(where: { $0.option.id == id }) else { return 0 }
        var chunk = 0
        while let end = Self.end(of: chunk, count: groups.count), index >= end { chunk += 1 }
        return chunk
    }

    // MARK: 分屏：一屏 12 格；后面还有时只放 11 个，最后一格是「更多」

    /// 第 `chunk` 屏放到第几个（不含）。最后一屏是 nil
    static func end(of chunk: Int, count: Int) -> Int? {
        let start = chunk * (perScreen - 1)
        return count - start > perScreen ? start + perScreen - 1 : nil
    }

    static func clamp(_ chunk: Int, count: Int) -> Int {
        var last = 0
        while end(of: last, count: count) != nil { last += 1 }
        return min(max(0, chunk), last)
    }

    static func chunk(_ items: [Cell], _ chunk: Int, more: Cell) -> [Cell] {
        let start = min(chunk * (perScreen - 1), items.count)
        guard let end = end(of: chunk, count: items.count) else { return Array(items[start...]) }
        return Array(items[start..<end]) + [more]
    }

    public static let allSymbol = "square.grid.2x2"
    public static let moreSymbol = "ellipsis"
    /// 收起时、还没选分类：统一用这个图标
    public static let unpickedSymbol = "tag"

    // MARK: 换语言

    /// 分类名称按 `name` 换，固定的字用 `labels`
    public func localized(name: (String) -> String, labels: Labels) -> LiveCategoryPicker {
        func option(_ value: Option) -> Option { Option(id: value.id, name: name(value.name), symbol: value.symbol) }
        return LiveCategoryPicker(
            quick: quick.map { Quick(option: option($0.option), opens: $0.opens) },
            groups: groups.map { Group(option: option($0.option), children: $0.children.map(option)) },
            labels: labels
        )
    }

    // MARK: 存起来、写进按钮

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}

extension LiveCategoryPicker.Page {
    /// 写进按钮动作的参数：`q`、`p.1`、`c.0.q.分类`（`q` 从推荐点进来，`p` 从大类点进来）
    public var token: String {
        switch self {
        case .quick: "q"
        case .parents(let chunk): "p.\(chunk)"
        case .children(let parentID, let chunk, let fromQuick): "c.\(chunk).\(fromQuick ? "q" : "p").\(parentID)"
        }
    }

    public init?(token: String) {
        let parts = token.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "q" where parts.count == 1:
            self = .quick
        case "p" where parts.count == 2:
            guard let chunk = Int(parts[1]) else { return nil }
            self = .parents(chunk: chunk)
        case "c" where parts.count == 4:
            guard let chunk = Int(parts[1]), ["q", "p"].contains(parts[2]), !parts[3].isEmpty else { return nil }
            self = .children(parentID: parts[3], chunk: chunk, fromQuick: parts[2] == "q")
        default:
            return nil
        }
    }
}

/// 有没有灵动岛：没有公开接口，按机型标识符判断（ADR 0024）。
/// iPhone 14 Pro（`iPhone15,2`）起的机型都有，只有 16e（`iPhone17,5`）、17e（`iPhone18,5`）还是刘海。
/// 以后的新机型按「有」算：判错了也只是锁屏卡片代替通知，照样能选
// 实时活动的内容要小于 4KB：页面和动作都存成一个短字符串，不用自动生成的嵌套 JSON

extension LiveCategoryPicker.Page {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let page = Self(token: token) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "页面 \(token)")
        }
        self = page
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

extension LiveCategoryPicker.Cell.Action {
    /// `k.分类`：记到这个分类；`s.页面`：换到这一页
    public var token: String {
        switch self {
        case .pick(let id): "k.\(id)"
        case .show(let page): "s.\(page.token)"
        }
    }

    public init?(token: String) {
        let body = String(token.dropFirst(2))
        if token.hasPrefix("k."), !body.isEmpty {
            self = .pick(body)
        } else if token.hasPrefix("s."), let page = LiveCategoryPicker.Page(token: body) {
            self = .show(page)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let action = Self(token: token) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "动作 \(token)")
        }
        self = action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

public enum DynamicIsland {
    static let notched: Set<String> = ["iPhone17,5", "iPhone18,5"]

    public static func isPresent(model: String) -> Bool {
        guard model.hasPrefix("iPhone"), !notched.contains(model) else { return false }
        let numbers = model.dropFirst("iPhone".count).split(separator: ",")
        guard numbers.count == 2, let major = Int(numbers[0]), Int(numbers[1]) != nil else { return false }
        return major >= 15
    }
}
