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

/// 给一笔流水推荐的分类，最可能的排在前面（待分类面板、记账结果通知的按钮）。
public struct CategorySuggestions: Hashable, Sendable {
    /// 待分类面板的「建议」，可能是小类
    public var categories: [LedgerCategory]
    /// 通知上的按钮，都是大类：只看小类的名字认不出是哪一类，选完大类再选小类
    public var topCategories: [LedgerCategory]
    /// 打开待分类面板时预先选好的：这个商户选过的分类。看不出商户、没选过、没确认对方的转账都是 nil
    public var preferredID: String?
    /// 这笔已经自动归到的分类（不在 `categories` 里）；nil 表示还没分类
    public var autoCategory: LedgerCategory?

    public init(categories: [LedgerCategory] = [], topCategories: [LedgerCategory] = [], preferredID: String? = nil, autoCategory: LedgerCategory? = nil) {
        self.categories = categories
        self.topCategories = topCategories
        self.preferredID = preferredID
        self.autoCategory = autoCategory
    }
}

/// 分类建议体检：拿已经选好分类的流水，按时间从早到晚一笔笔重新推荐，每笔只用它之前的记录，看建议准不准（ADR 0017）。
public struct CategoryCheckup: Hashable, Sendable {
    /// 一组流水里，建议对上了几笔
    public struct Score: Hashable, Sendable {
        public var count: Int
        /// 第 1 个建议就是选的分类
        public var first: Int
        /// 待分类面板的「建议」里有选的分类
        public var panel: Int
        /// 记账结果通知的大类按钮里有选的分类所在的大类
        public var notification: Int
        /// 在通知上选完一共要点几下（估算）
        public var taps: Int

        public init(count: Int = 0, first: Int = 0, panel: Int = 0, notification: Int = 0, taps: Int = 0) {
            self.count = count
            self.first = first
            self.panel = panel
            self.notification = notification
            self.taps = taps
        }

        /// 平均每笔点几下；一笔都没有时是 nil
        public var averageTaps: Double? { count == 0 ? nil : Double(taps) / Double(count) }
    }

    /// 同一个商户连续选 `streak` 次同一个分类就自动归类时：会自动归几笔，其中几笔和选的不一样
    public struct AutoFiling: Hashable, Sendable {
        public var streak: Int
        public var filed: Int
        public var wrong: Int

        public init(streak: Int, filed: Int = 0, wrong: Int = 0) {
            self.streak = streak
            self.filed = filed
            self.wrong = wrong
        }
    }

    public var all: Score
    /// 认得出商户的
    public var withMerchant: Score
    /// 看不出商户的（中行这样不写商户的通知、收款码、手动记的没填交易对方）
    public var withoutMerchant: Score
    /// 自动记账记的笔数，其余是手动记的
    public var automatic: Int
    /// 第一个是现在用的次数，后面是换个次数会怎样
    public var autoFiling: [AutoFiling]

    public init(all: Score = Score(), withMerchant: Score = Score(), withoutMerchant: Score = Score(), automatic: Int = 0, autoFiling: [AutoFiling] = []) {
        self.all = all
        self.withMerchant = withMerchant
        self.withoutMerchant = withoutMerchant
        self.automatic = automatic
        self.autoFiling = autoFiling
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
