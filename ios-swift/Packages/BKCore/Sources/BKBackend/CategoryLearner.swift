import Foundation
import BKModel
import BKDatabase

/// 在本机学习分类（ADR 0017）：记下用户给每个商户选过什么，用来排候选；连续选同一个分类才自动归类。
/// 不联网，不按时间猜三餐。看不出商户的（`MerchantName.key` 是 nil）不学习、不自动归类，只按常用分类排序。
/// 所有函数都在 `Database.read/write` 的闭包里执行。
struct CategoryLearner {
    /// 连续选几次同一个分类，下一笔才自动归类
    static let autoStreak = 3
    /// 候选最多几个
    static let suggestionLimit = 4
    /// 这些性质的分类是通知写明的，或者跟着原交易，不是用户的选择
    static let ruleKinds: Set<TransactionKind> = [.fee, .interestCharge, .salary, .interestIncome, .refund, .reversal]

    let db: SQLiteConnection

    /// 「类型|商户」：同一个对方的支出和收入分开学
    private func merchant(of record: LedgerRecord) -> String? {
        MerchantName.key(record.counterparty).map { "\(CategoryType(record.entryType).rawValue)|\($0)" }
    }

    /// 用户给这笔选了分类
    func learn(_ record: LedgerRecord, categoryID: String, at time: Date) throws {
        guard !Self.ruleKinds.contains(record.kind), let merchant = merchant(of: record) else { return }
        try MerchantCategoryDAO.addPick(db, merchant: merchant, categoryID: categoryID, at: time)
    }

    /// 连续选够次数时可以自动归的分类
    func autoCategory(for record: LedgerRecord, tree: CategoryTree) throws -> LedgerCategory? {
        guard let merchant = merchant(of: record), let latest = try MerchantCategoryDAO.picks(db, merchant: merchant).first,
              latest.streak >= Self.autoStreak else { return nil }
        return usable(latest.categoryID, type: CategoryType(record.entryType), tree: tree)
    }

    /// 这笔的候选：这个商户选过的分类（最近选的在前），不够用常用分类补齐，再不够按分类的顺序。
    /// 不用选的（转帐、已经有分类的）没有候选；自动归的可以改，候选里去掉现在这个分类
    func suggestions(for record: LedgerRecord, tree: CategoryTree) throws -> CategorySuggestions {
        let type = CategoryType(record.entryType)
        guard record.status == .posted, type != .transfer, record.categoryID == nil || record.categoryAuto else { return CategorySuggestions() }
        let learned = try merchant(of: record).map { try MerchantCategoryDAO.picks(db, merchant: $0).map(\.categoryID) } ?? []
        let ordered = learned + (try RecordDAO.frequentCategories(db, type: type)) + tree.nodes(type).map(\.id)
        var categories: [LedgerCategory] = []
        for id in ordered where categories.count < Self.suggestionLimit && id != record.categoryID {
            guard let category = usable(id, type: type, tree: tree), !category.locked, !categories.contains(category) else { continue }
            categories.append(category)
        }
        let first = categories.first?.id
        let preferred = record.categoryID == nil && !record.needsTransferConfirmation && learned.contains { $0 == first } ? first : nil
        return CategorySuggestions(categories: categories, preferredID: preferred, autoCategory: tree.category(record.categoryID))
    }

    /// 隐藏的分类（包括隐藏的大类下面的小类）不能用
    private func usable(_ id: String, type: CategoryType, tree: CategoryTree) -> LedgerCategory? {
        guard let category = tree.category(id), category.type == type, !category.hidden, tree.category(category.parentID)?.hidden != true else { return nil }
        return category
    }
}
