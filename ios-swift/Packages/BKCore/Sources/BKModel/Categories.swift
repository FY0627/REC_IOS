import Foundation

/// 分类属于哪一种记账类型。支出、收入的分类由用户自己定；转帐的分类按交易性质自动对应。
public enum CategoryType: String, Sendable, Codable, CaseIterable {
    case expense
    case income
    case transfer

    public var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转帐"
        }
    }

    public var entryType: EntryType {
        switch self {
        case .expense: .expense
        case .income: .income
        case .transfer: .transfer
        }
    }

    public init(_ entryType: EntryType) {
        switch entryType {
        case .expense: self = .expense
        case .income: self = .income
        case .transfer: self = .transfer
        }
    }
}

/// 一个分类：大类（`parentID` 为 nil）或小类，最多两层。
/// 默认的那套只是第一次打开时写进数据库的起点，之后用户可以增加、删除、改名、换图标、排序、隐藏。
public struct LedgerCategory: Identifiable, Hashable, Sendable {
    public var id: String
    public var type: CategoryType
    public var parentID: String?
    public var name: String
    /// SF Symbols 图标名
    public var symbol: String
    public var sortOrder: Int
    /// 隐藏：记账时不出现，已有记录不变
    public var hidden: Bool
    /// 自动归类用的标识（手续费、扣息、工资、转帐……）；用户自己加的分类为 nil
    public var autoKey: String?
    /// 转帐和系统分类：自动记账要用，不能删除，可以改名和换图标
    public var locked: Bool

    public init(
        id: String, type: CategoryType, parentID: String?, name: String, symbol: String, sortOrder: Int,
        hidden: Bool = false, autoKey: String? = nil, locked: Bool = false
    ) {
        self.id = id
        self.type = type
        self.parentID = parentID
        self.name = name
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.hidden = hidden
        self.autoKey = autoKey
        self.locked = locked
    }

    public var isTopLevel: Bool { parentID == nil }
}

/// 自动归类用的分类标识。
public enum CategoryKey {
    /// 手续费（系统）
    public static let fee = "fee"
    /// 扣息（系统）
    public static let interestCharge = "interest"
    public static let salary = "salary"
    public static let interestIncome = "interestIncome"
    /// 默认分类里的饮食大类和三餐（迁移 8 写入的标识，现在不再按时间猜）
    public static let food = "food"
    public static let breakfast = "food.breakfast"
    public static let lunch = "food.lunch"
    public static let dinner = "food.dinner"
    /// 转帐：自己的账户之间互转、还信用卡、存取现金
    public static let transferOwn = "transfer.own"
    public static let repayment = "transfer.repayment"
    public static let cash = "transfer.cash"

    /// 转帐按交易性质对应的分类
    public static func transfer(for kind: TransactionKind) -> String {
        switch kind {
        case .repayment: repayment
        case .deposit, .withdrawal: cash
        default: transferOwn
        }
    }
}

/// 分类的整理结果：大类和它下面的小类，按顺序排好。
public struct CategoryTree: Hashable, Sendable {
    public struct Node: Hashable, Sendable, Identifiable {
        public var category: LedgerCategory
        public var children: [LedgerCategory]
        public var id: String { category.id }
    }

    public var all: [LedgerCategory]

    public init(_ all: [LedgerCategory]) {
        self.all = all
    }

    /// 某种类型的大类和小类；`includeHidden` 为 false 时去掉隐藏的
    public func nodes(_ type: CategoryType, includeHidden: Bool = false) -> [Node] {
        let visible = all.filter { $0.type == type && (includeHidden || !$0.hidden) }
        let children = Dictionary(grouping: visible.filter { $0.parentID != nil }, by: { $0.parentID ?? "" })
        return visible.filter(\.isTopLevel).sorted(by: Self.order).map { parent in
            Node(category: parent, children: (children[parent.id] ?? []).sorted(by: Self.order))
        }
    }

    public func category(_ id: String?) -> LedgerCategory? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public func category(autoKey: String) -> LedgerCategory? {
        all.first { $0.autoKey == autoKey }
    }

    public func label(_ id: String?) -> CategoryLabel? {
        guard let category = category(id) else { return nil }
        let parent = self.category(category.parentID)
        return CategoryLabel(id: category.id, name: category.name, symbol: category.symbol, parentName: parent?.name)
    }

    /// 小类所在的大类，大类是它自己
    public func topLevel(_ id: String?) -> LedgerCategory? {
        guard let category = category(id) else { return nil }
        return self.category(category.parentID) ?? category
    }

    static func order(_ a: LedgerCategory, _ b: LedgerCategory) -> Bool {
        a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.id < b.id
    }
}

/// 新增分类时由界面填写的内容。
public struct CategoryDraft: Hashable, Sendable {
    public var type: CategoryType
    /// 加在哪个大类下面；nil 是新的大类
    public var parentID: String?
    public var name: String
    public var symbol: String

    public init(type: CategoryType, parentID: String?, name: String, symbol: String) {
        self.type = type
        self.parentID = parentID
        self.name = name
        self.symbol = symbol
    }
}

/// 分类图标可选的 SF Symbols。
public enum CategorySymbols {
    public static let all = [
        "fork.knife", "sunrise", "sun.max", "moon.stars", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "popcorn", "birthday.cake",
        "cart", "basket", "bag", "tshirt", "shoeprints.fill", "eyeglasses", "comb", "sparkles",
        "house", "key", "bolt", "drop", "flame", "wifi", "phone", "sofa",
        "car", "car.fill", "tram.fill", "bus", "bicycle", "fuelpump", "parkingsign", "airplane",
        "book", "book.closed", "graduationcap", "pencil", "laptopcomputer", "iphone", "headphones", "camera",
        "gamecontroller", "film", "music.note", "ticket", "suitcase", "figure.run", "dumbbell", "tent",
        "cross.case", "pills", "heart", "stethoscope", "gift", "envelope", "person.2", "pawprint",
        "figure.and.child.holdinghands", "briefcase", "star", "chart.line.uptrend.xyaxis", "banknote", "creditcard", "building.columns", "percent",
        "doc.text", "wrench.and.screwdriver", "scissors", "leaf", "arrow.left.arrow.right", "arrow.uturn.backward", "ellipsis.circle", "tag",
    ]
}
