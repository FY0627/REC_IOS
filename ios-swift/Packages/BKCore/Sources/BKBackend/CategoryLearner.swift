import Foundation
import BKModel
import BKDatabase

/// 在本机学习分类（ADR 0017、ADR 0026）：记下用户给每个商户选过什么，用来排候选；连续选同一个分类才自动归类。
/// 不联网。看不出商户的（`MerchantName.key` 是 nil）不学习、不自动归类，只按常用分类排序。
///
/// 按时段分开记（`MealSlot`）：每次选择同时记在「这个商户」和「这个商户在这个时段」下面。
/// 自动归类先看这个时段连续选的，再看不分时段连续选的，所以不是饭点时选了一次别的，饭点照样自动归类。
/// 学到的是早餐、午餐、晚餐之一时，换到别的饭点就是那一餐，不是饭点不自动归。
/// 没学过的商户，小词库（`CategoryLexicon`）猜的分类排在推荐第一个，只排序不自动归。
/// 所有函数都在 `Database.read/write` 的闭包里执行。
struct CategoryLearner {
    /// 连续选几次同一个分类，下一笔才自动归类
    static let autoStreak = 3
    /// 待分类面板的候选最多几个
    static let suggestionLimit = 4
    /// 灵动岛第 1 页的推荐几个（ADR 0024）
    static let quickLimit = LiveCategoryPicker.quickCount
    /// 这些性质的分类是通知写明的，或者跟着原交易，不是用户的选择
    static let ruleKinds: Set<TransactionKind> = [.fee, .interestCharge, .salary, .interestIncome, .refund, .reversal]
    /// 时段接在商户后面记（「商户」+ 这个字符 + 时段），和不分时段的分开
    static let slotSeparator = "\u{1F}"

    let db: SQLiteConnection
    let calendar: Calendar
    /// 一次回放很多笔时先算好的饭点；nil 时每次按账本算
    var times: MealTimes?

    init(db: SQLiteConnection, calendar: Calendar, times: MealTimes? = nil) {
        self.db = db
        self.calendar = calendar
        self.times = times
    }

    /// 「类型|商户」：同一个对方的支出和收入分开学
    func merchant(of record: LedgerRecord) -> String? {
        MerchantName.key(record.counterparty).map { "\(CategoryType(record.entryType).rawValue)|\($0)" }
    }

    /// 这一笔在哪个时段
    func slot(of record: LedgerRecord, tree: CategoryTree) throws -> MealSlot {
        let times = try self.times ?? MealTimes.load(db, tree: tree, calendar: calendar)
        return times.slot(minute: MealTimes.minuteOfDay(record, calendar: calendar))
    }

    static func slotKey(_ merchant: String, _ slot: MealSlot) -> String {
        merchant + slotSeparator + slot.rawValue
    }

    /// 用户给这笔选了分类；`previous` 是这笔原来的分类
    func learn(_ record: LedgerRecord, categoryID: String, replacing previous: String? = nil, at time: Date) throws {
        guard !Self.ruleKinds.contains(record.kind), let merchant = merchant(of: record) else { return }
        try learn(key: merchant, categoryID: categoryID, replacing: previous, at: time)
        try learnSlot(record, merchant: merchant, categoryID: categoryID, replacing: previous, at: time)
    }

    /// 只记到时段上（时段是后来加的：以前学过的按流水回放一遍补上，`LedgerBackend.seedCategoryLearning`）
    func learnSlot(_ record: LedgerRecord, categoryID: String, at time: Date) throws {
        guard !Self.ruleKinds.contains(record.kind), let merchant = merchant(of: record) else { return }
        try learnSlot(record, merchant: merchant, categoryID: categoryID, replacing: nil, at: time)
    }

    private func learnSlot(_ record: LedgerRecord, merchant: String, categoryID: String, replacing previous: String?, at time: Date) throws {
        let slot = try slot(of: record, tree: CategoryTree(try CategoryDAO.all(db)))
        try learn(key: Self.slotKey(merchant, slot), categoryID: categoryID, replacing: previous, at: time)
    }

    private func learn(key: String, categoryID: String, replacing previous: String?, at time: Date) throws {
        if let latest = try MerchantCategoryDAO.picks(db, merchant: key).first?.categoryID {
            // 选了大类，最近选的是它下面的小类：不算改主意，这一笔可能接着选小类
            if try CategoryDAO.find(db, id: latest)?.parentID == categoryID { return }
            // 这一笔刚选了大类，接着选它下面的小类：两步算一次选择
            if latest == previous, try CategoryDAO.find(db, id: categoryID)?.parentID == latest {
                try MerchantCategoryDAO.refine(db, merchant: key, from: latest, to: categoryID, at: time)
                return
            }
        }
        try MerchantCategoryDAO.addPick(db, merchant: key, categoryID: categoryID, at: time)
    }

    /// 连续选够次数时可以自动归的分类。`streak` 只有体检时改，看换个次数会怎样。
    /// 先看这个时段连续选的；再看不分时段连续选的，学到的是三餐之一时换成这个时段的那一餐，不是饭点不自动归
    func autoCategory(for record: LedgerRecord, tree: CategoryTree, streak: Int = Self.autoStreak) throws -> LedgerCategory? {
        guard let merchant = merchant(of: record) else { return nil }
        let type = CategoryType(record.entryType)
        let slot = try slot(of: record, tree: tree)
        if let latest = try MerchantCategoryDAO.picks(db, merchant: Self.slotKey(merchant, slot)).first, latest.streak >= streak {
            return usable(latest.categoryID, type: type, tree: tree)
        }
        guard let latest = try MerchantCategoryDAO.picks(db, merchant: merchant).first, latest.streak >= streak,
              let category = usable(latest.categoryID, type: type, tree: tree) else { return nil }
        guard MealSlot.meal(of: category) != nil else { return category }
        return mealCategory(for: slot, type: type, tree: tree)
    }

    /// 这个时段的那一餐（默认分类里的早餐、午餐、晚餐）；不是饭点、或者那一餐的分类不能用时是 nil
    func mealCategory(for slot: MealSlot, type: CategoryType, tree: CategoryTree) -> LedgerCategory? {
        slot.mealKey.flatMap { tree.category(autoKey: $0) }.flatMap { usable($0.id, type: type, tree: tree) }
    }

    /// 这笔的候选：这个商户这个时段选过的、不分时段选过的（三餐换成这个时段的那一餐），没选过时小词库猜的，
    /// 再用常用分类补齐（这个时段常用的在前），再不够按分类的顺序。
    /// 不用选的（转帐、已经有分类的）没有候选；自动归的可以改，面板的候选里去掉现在这个分类。
    /// 通知上的大类（`groups`，ADR 0020）用同一个顺序：全部能选的大类都在，选过、常用的在前；每个大类的小类也是选过、常用的在前，其余按分类顺序
    func suggestions(for record: LedgerRecord, tree: CategoryTree) throws -> CategorySuggestions {
        let type = CategoryType(record.entryType)
        guard record.status == .posted, type != .transfer, record.categoryID == nil || record.categoryAuto else { return CategorySuggestions() }
        let times = try self.times ?? MealTimes.load(db, tree: tree, calendar: calendar)
        let slot = times.slot(minute: MealTimes.minuteOfDay(record, calendar: calendar))
        let learned = try learnedCategories(for: record, slot: slot, tree: tree)
        let guessed = learned.isEmpty ? CategoryLexicon.guess(record.counterparty, type: type, slot: slot, tree: tree).map { [$0.id] } ?? [] : []
        let frequent = try frequentCategories(type: type, slot: slot, times: times)
        let ordered = learned + guessed + frequent + tree.nodes(type).map(\.id)
        var categories: [LedgerCategory] = []
        var quick: [LedgerCategory] = []
        var parents: [LedgerCategory] = []
        for id in ordered {
            guard let category = usable(id, type: type, tree: tree), !category.locked else { continue }
            if quick.count < Self.quickLimit, id != record.categoryID, !quick.contains(category) {
                quick.append(category)
                if categories.count < Self.suggestionLimit { categories.append(category) }
            }
            if let top = tree.topLevel(id), !top.locked, !parents.contains(top) { parents.append(top) }
        }
        // 小类：在上面的顺序里出现得早的在前，没出现的按分类顺序
        let rank = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let nodes = tree.nodes(type)
        let groups = parents.map { parent in
            let children = (nodes.first { $0.id == parent.id }?.children ?? []).enumerated()
                .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
                .map(\.element)
            return CategoryGroup(parent: parent, children: children)
        }
        let first = categories.first?.id
        let preferred = record.categoryID == nil && !record.needsTransferConfirmation && learned.contains { $0 == first } ? first : nil
        return CategorySuggestions(
            categories: categories, groups: groups, preferredID: preferred, autoCategory: tree.category(record.categoryID),
            quick: quick, learnedIDs: Set(learned + frequent)
        )
    }

    /// 这个商户选过的分类：这个时段选过的在前，再是不分时段的（三餐换成这个时段的那一餐），各自最近选的在前
    private func learnedCategories(for record: LedgerRecord, slot: MealSlot, tree: CategoryTree) throws -> [String] {
        guard let merchant = merchant(of: record) else { return [] }
        let type = CategoryType(record.entryType)
        let inSlot = try MerchantCategoryDAO.picks(db, merchant: Self.slotKey(merchant, slot)).map(\.categoryID)
        let meal = mealCategory(for: slot, type: type, tree: tree)?.id
        let overall = try MerchantCategoryDAO.picks(db, merchant: merchant).map(\.categoryID).map { id -> String in
            guard let meal, let category = tree.category(id), MealSlot.meal(of: category) != nil else { return id }
            return meal
        }
        var seen = Set<String>()
        return (inSlot + overall).filter { seen.insert($0).inserted }
    }

    /// 最近用得多的分类：饭点时这个饭点用得多的在前，再按全天用得多的，一样多时最近用的在前。
    /// 不是饭点的时候各种事都有（下午买东西、交话费），不按时段排
    private func frequentCategories(type: CategoryType, slot: MealSlot, times: MealTimes) throws -> [String] {
        var inSlot: [String: Int] = [:]
        var overall: [String: Int] = [:]
        var latest: [String: Int] = [:]
        for (index, record) in try RecordDAO.recentCategorized(db, type: type).enumerated() {
            guard let id = record.categoryID else { continue }
            overall[id, default: 0] += 1
            if latest[id] == nil { latest[id] = index }
            if slot != .other, times.slot(minute: MealTimes.minuteOfDay(record, calendar: calendar)) == slot { inSlot[id, default: 0] += 1 }
        }
        return overall.keys.sorted { a, b in
            let slotA = inSlot[a] ?? 0, slotB = inSlot[b] ?? 0
            if slotA != slotB { return slotA > slotB }
            if overall[a] != overall[b] { return overall[a] ?? 0 > overall[b] ?? 0 }
            if latest[a] != latest[b] { return latest[a] ?? 0 < latest[b] ?? 0 }
            return a < b
        }
    }

    /// 隐藏的分类（包括隐藏的大类下面的小类）不能用
    private func usable(_ id: String, type: CategoryType, tree: CategoryTree) -> LedgerCategory? {
        guard let category = tree.category(id), category.type == type, !category.hidden, tree.category(category.parentID)?.hidden != true else { return nil }
        return category
    }
}
