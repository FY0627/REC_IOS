import Foundation
import BKModel
import BKDatabase

/// 在本机学习分类（ADR 0017）：记下用户给每个商户选过什么，用来排候选；连续选同一个分类才自动归类。
/// 不联网，不按时间猜三餐。看不出商户的（`MerchantName.key` 是 nil）不学习、不自动归类，只按常用分类排序。
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

    let db: SQLiteConnection

    /// 「类型|商户」：同一个对方的支出和收入分开学
    func merchant(of record: LedgerRecord) -> String? {
        MerchantName.key(record.counterparty).map { "\(CategoryType(record.entryType).rawValue)|\($0)" }
    }

    /// 用户给这笔选了分类；`previous` 是这笔原来的分类
    func learn(_ record: LedgerRecord, categoryID: String, replacing previous: String? = nil, at time: Date) throws {
        guard !Self.ruleKinds.contains(record.kind), let merchant = merchant(of: record) else { return }
        if let latest = try MerchantCategoryDAO.picks(db, merchant: merchant).first?.categoryID {
            // 选了大类，最近选的是它下面的小类：不算改主意，这一笔可能接着选小类
            if try CategoryDAO.find(db, id: latest)?.parentID == categoryID { return }
            // 这一笔刚选了大类，接着选它下面的小类：两步算一次选择
            if latest == previous, try CategoryDAO.find(db, id: categoryID)?.parentID == latest {
                try MerchantCategoryDAO.refine(db, merchant: merchant, from: latest, to: categoryID, at: time)
                return
            }
        }
        try MerchantCategoryDAO.addPick(db, merchant: merchant, categoryID: categoryID, at: time)
    }

    /// 连续选够次数时可以自动归的分类。`streak` 只有体检时改，看换个次数会怎样
    func autoCategory(for record: LedgerRecord, tree: CategoryTree, streak: Int = Self.autoStreak) throws -> LedgerCategory? {
        guard let merchant = merchant(of: record), let latest = try MerchantCategoryDAO.picks(db, merchant: merchant).first,
              latest.streak >= streak else { return nil }
        return usable(latest.categoryID, type: CategoryType(record.entryType), tree: tree)
    }

    /// 这笔的候选：这个商户选过的分类（最近选的在前），不够用常用分类补齐，再不够按分类的顺序。
    /// 不用选的（转帐、已经有分类的）没有候选；自动归的可以改，面板的候选里去掉现在这个分类。
    /// 通知上的大类（`groups`，ADR 0020）用同一个顺序：全部能选的大类都在，选过、常用的在前；每个大类的小类也是选过、常用的在前，其余按分类顺序
    func suggestions(for record: LedgerRecord, tree: CategoryTree) throws -> CategorySuggestions {
        let type = CategoryType(record.entryType)
        guard record.status == .posted, type != .transfer, record.categoryID == nil || record.categoryAuto else { return CategorySuggestions() }
        let learned = try learnedCategories(for: record)
        let chosen = learned + (try RecordDAO.frequentCategories(db, type: type))
        let ordered = chosen + tree.nodes(type).map(\.id)
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
            quick: quick, learnedIDs: Set(chosen)
        )
    }

    /// 这个商户选过的分类，最近选的在前
    private func learnedCategories(for record: LedgerRecord) throws -> [String] {
        try merchant(of: record).map { try MerchantCategoryDAO.picks(db, merchant: $0).map(\.categoryID) } ?? []
    }

    /// 隐藏的分类（包括隐藏的大类下面的小类）不能用
    private func usable(_ id: String, type: CategoryType, tree: CategoryTree) -> LedgerCategory? {
        guard let category = tree.category(id), category.type == type, !category.hidden, tree.category(category.parentID)?.hidden != true else { return nil }
        return category
    }
}
