import Foundation

/// 记账结果通知上选分类（ADR 0020）：长按通知后的按钮。系统最多给 4 个按钮：3 个放选项，第 4 个翻页、返回或打开 App。
///
/// - 先是大类：这个商户选过的分类放在第一个（点了直接记），后面是全部大类，常选的在前，没用过的按分类顺序在后，
///   一页 3 个，「更多大类」翻页，最后一页的第 4 个是「打开 App」；
/// - 点有小类的大类，按钮当场换成它的小类（常选的在前），最后加一个「只记这个大类」，同样一页 3 个，最后一页是「返回」；
/// - 点到一个分类（`pick.分类`），通知扩展把它交回 App 保存。
///
/// App 发通知时把它写进 userInfo（`json`），通知扩展读出来换按钮。扩展和 App 共用这份逻辑，分类建议体检也用它算点几下
public struct NotificationPicker: Hashable, Sendable, Codable {
    public struct Option: Hashable, Sendable, Codable {
        public var id: String
        public var name: String
        public var symbol: String

        public init(id: String, name: String, symbol: String) {
            self.id = id
            self.name = name
            self.symbol = symbol
        }

        public init(_ category: LedgerCategory) {
            self.init(id: category.id, name: category.name, symbol: category.symbol)
        }
    }

    public struct Group: Hashable, Sendable, Codable {
        public var option: Option
        public var children: [Option]

        public init(option: Option, children: [Option]) {
            self.option = option
            self.children = children
        }
    }

    public enum Button: Hashable, Sendable {
        /// 记到这个分类：交回 App
        case pick(Option, title: String)
        /// 有小类的大类：换成它的小类
        case open(Option)
        /// 大类的第几页
        case parents(page: Int, title: String)
        /// 这个大类的小类的第几页
        case children(parentID: String, page: Int)
        /// 打开 App 选（点通知本身也一样）
        case app
    }

    /// 一页放几个选项（第 4 个按钮留给翻页、返回或打开 App）
    public static let perPage = 3

    public var first: Option?
    public var groups: [Group]

    public init(first: Option?, groups: [Group]) {
        self.first = first
        self.groups = groups
    }

    // MARK: 按钮

    /// 第一层的选项：这个商户选过的，再是全部大类（选过的就是一个没有小类的大类时不再列一次）
    var parentItems: [Button] {
        let parents = groups.compactMap { group -> Button? in
            if group.children.isEmpty {
                return group.option.id == first?.id ? nil : .pick(group.option, title: group.option.name)
            }
            return .open(group.option)
        }
        return (first.map { [Button.pick($0, title: $0.name)] } ?? []) + parents
    }

    /// 第二层的选项：小类，最后是「只记这个大类」
    func childItems(_ group: Group) -> [Button] {
        group.children.map { Button.pick($0, title: $0.name) } + [.pick(group.option, title: "只记\(group.option.name)")]
    }

    /// 大类的第 `page` 页（从 0 开始）
    public func parentButtons(page: Int) -> [Button] {
        Self.paged(parentItems, page: page, next: .parents(page: page + 1, title: "更多大类"), last: .app)
    }

    /// 这个大类的小类的第 `page` 页
    public func childButtons(of parentID: String, page: Int) -> [Button] {
        guard let group = groups.first(where: { $0.option.id == parentID }) else { return parentButtons(page: 0) }
        return Self.paged(childItems(group), page: page, next: .children(parentID: parentID, page: page + 1), last: .parents(page: 0, title: "返回"))
    }

    static func paged(_ items: [Button], page: Int, next: Button, last: Button) -> [Button] {
        let start = min(max(0, page) * perPage, max(0, items.count - 1))
        let slice = Array(items[start..<min(items.count, start + perPage)])
        return slice + [start + perPage < items.count ? next : last]
    }

    /// 从长按通知算起，再点几下能记到这个分类：翻页、点大类、翻小类、点小类各算一下。找不到时是 nil
    public func taps(to categoryID: String) -> Int? {
        if let index = parentItems.firstIndex(where: { $0.optionID == categoryID }) {
            return index / Self.perPage + 1
        }
        for group in groups where group.children.contains(where: { $0.id == categoryID }) {
            guard let parent = parentItems.firstIndex(where: { $0.optionID == group.option.id }),
                  let child = childItems(group).firstIndex(where: { $0.optionID == categoryID }) else { continue }
            return parent / Self.perPage + 1 + child / Self.perPage + 1
        }
        return nil
    }

    /// 第一页就有：这个分类，或者它所在的大类
    public func onFirstPage(_ categoryID: String) -> Bool {
        let firstPage = parentItems.prefix(Self.perPage).compactMap(\.optionID)
        if firstPage.contains(categoryID) { return true }
        return groups.contains { group in group.children.contains { $0.id == categoryID } && firstPage.contains(group.option.id) }
    }

    // MARK: 按钮的标识

    public static let pickPrefix = "pick."
    /// 有小类的大类。扩展把它换成小类；扩展没起来、点击交到 App 时，App 就记到这个大类
    public static let openPrefix = "open."
    public static let appIdentifier = "more"

    /// 通知扩展认的一组通知类别（`Config/NotificationContent-Info.plist` 的 `UNNotificationExtensionCategory` 要和它一致）。
    /// 每条通知轮着用一个，类别上预先写好这条通知的第一页按钮：长按时系统马上显示，不用等扩展起来
    public static let categoryIDs = (0..<20).map { "ingest.pick.\($0)" }

    public static func identifier(_ button: Button) -> String {
        switch button {
        case .pick(let option, _): pickPrefix + option.id
        case .open(let option): openPrefix + option.id
        case .parents(let page, _): "parents.\(page)"
        case .children(let parentID, let page): "children.\(page).\(parentID)"
        case .app: appIdentifier
        }
    }

    /// 通知扩展收到点击：要换成哪一页。`pick.`、打开 App 不在这里（交回 App）
    public func buttons(after identifier: String) -> [Button]? {
        let parts = identifier.split(separator: ".", maxSplits: 2).map(String.init)
        switch parts.first {
        case "parents": return parentButtons(page: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        case "open": return childButtons(of: String(identifier.dropFirst(Self.openPrefix.count)), page: 0)
        case "children" where parts.count == 3: return childButtons(of: parts[2], page: Int(parts[1]) ?? 0)
        default: return nil
        }
    }

    // MARK: 写进通知

    public static let userInfoKey = "picker"

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public init?(json: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}

extension NotificationPicker.Button {
    /// 选项对应的分类；翻页、返回、打开 App 没有
    var optionID: String? {
        switch self {
        case .pick(let option, _), .open(let option): option.id
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .pick(_, let title): title
        case .open(let option): option.name
        case .parents(_, let title): title
        case .children: "更多"
        case .app: "打开 App"
        }
    }

    /// SF Symbols 图标名
    public var symbol: String {
        switch self {
        case .pick(let option, _), .open(let option): option.symbol
        case .parents(let page, _): page == 0 ? "chevron.backward" : "ellipsis"
        case .children: "ellipsis"
        case .app: "ellipsis.circle"
        }
    }
}
