import Foundation
import BKModel
import BKDatabase

/// 分类建议体检（ADR 0017）：把已经有分类的流水按时间从早到晚放进一个临时的内存数据库，
/// 每一笔先用它之前的记录算出建议（和待分类面板、记账结果通知用的是同一个 `CategoryLearner`），再记上它的分类、学一次。
/// 只读用户的账本，不改它，也不碰学到的规律。
///
/// 只给用户自己选的分类打分：自动归的、通知写明的（手续费、扣息、工资、利息）、退款和现在隐藏的分类不算，
/// 但这些流水照样放进临时数据库，「常用分类」和用户的账本里一样。
/// 看不到用户当时一步步怎么点的，只按最后的分类学；在通知上先选大类、再选小类时，第二步的候选是估算的
enum CategoryCheckupReplay {
    /// 看连续选几次就自动归类会怎样：现在是 3 次，另外算 2 次
    static let streaks = [CategoryLearner.autoStreak, 2]

    static func run(_ db: SQLiteConnection, now: Date) throws -> CategoryCheckup {
        let categories = try CategoryDAO.all(db)
        let tree = CategoryTree(categories)
        let records = try RecordDAO.categorized(db, includingAuto: true)

        let replay = try SQLiteConnection(path: ":memory:")
        try Migrations.migrate(replay)
        return try replay.immediateTransaction {
            try replay.execute("DELETE FROM categories")
            for category in categories { try CategoryDAO.insert(replay, category, now: now) }
            let learner = CategoryLearner(db: replay)
            var result = CategoryCheckup(autoFiling: streaks.map { CategoryCheckup.AutoFiling(streak: $0) })
            for record in records {
                if let chosen = chosenCategory(record, tree: tree) {
                    try score(record, chosen: chosen, learner: learner, tree: tree, into: &result)
                    _ = try RecordDAO.insertIfAbsent(replay, record, dedupeKey: record.id, now: now)
                    try learner.learn(record, categoryID: chosen.id, at: record.effectiveAt)
                } else {
                    _ = try RecordDAO.insertIfAbsent(replay, record, dedupeKey: record.id, now: now)
                }
            }
            return result
        }
    }

    /// 用户自己选的、现在还能选到的分类；其余的不打分
    static func chosenCategory(_ record: LedgerRecord, tree: CategoryTree) -> LedgerCategory? {
        guard !record.categoryAuto, !CategoryLearner.ruleKinds.contains(record.kind), let category = tree.category(record.categoryID),
              category.type != .transfer, category.type == CategoryType(record.entryType), !category.locked, !category.hidden,
              tree.category(category.parentID)?.hidden != true else { return nil }
        return category
    }

    /// 这一笔还没分类时的样子。没配对的转账在选分类之前还没确认对方（选了分类才算转给别人）
    static func uncategorized(_ record: LedgerRecord) -> LedgerRecord {
        var blank = record
        blank.categoryID = nil
        blank.categoryAuto = false
        if blank.transferGroupID == nil, blank.transferParty == .other, blank.kind == .transferIn || blank.kind == .transferOut {
            blank.transferParty = nil
        }
        return blank
    }

    private static func score(
        _ record: LedgerRecord, chosen: LedgerCategory, learner: CategoryLearner, tree: CategoryTree, into result: inout CategoryCheckup
    ) throws {
        let blank = uncategorized(record)
        let suggestions = try learner.suggestions(for: blank, tree: tree)
        // 没确认对方的转账不自动归类（`Categorizer`）
        var auto: [Int: LedgerCategory] = [:]
        if !blank.needsTransferConfirmation {
            for streak in streaks { auto[streak] = try learner.autoCategory(for: blank, tree: tree, streak: streak) }
        }
        let tapCount = auto[CategoryLearner.autoStreak] == chosen
            ? 0 : try taps(chosen, blank: blank, suggestions: suggestions, learner: learner, tree: tree)

        var score = CategoryCheckup.Score(count: 1, taps: tapCount)
        if suggestions.categories.first == chosen { score.first = 1 }
        if suggestions.categories.contains(chosen) { score.panel = 1 }
        if let top = tree.topLevel(chosen.id), suggestions.topCategories.contains(top) { score.notification = 1 }

        add(score, to: &result.all)
        if learner.merchant(of: blank) != nil {
            add(score, to: &result.withMerchant)
        } else {
            add(score, to: &result.withoutMerchant)
        }
        if record.source != .manual { result.automatic += 1 }
        for index in result.autoFiling.indices {
            guard let filed = auto[result.autoFiling[index].streak] else { continue }
            result.autoFiling[index].filed += 1
            if filed != chosen { result.autoFiling[index].wrong += 1 }
        }
    }

    private static func add(_ score: CategoryCheckup.Score, to total: inout CategoryCheckup.Score) {
        total.count += score.count
        total.first += score.first
        total.panel += score.panel
        total.notification += score.notification
        total.taps += score.taps
    }

    /// 在记账结果通知上把这笔选成 `chosen` 要点几下（估算）：长按通知、点一个按钮各算一下。
    /// - 大类按钮里有它的大类：点大类 2 下；它是小类时再长按第二条通知点小类，共 4 下；第二条的候选里没有，点开第二条在面板里选，共 5 下；
    /// - 没有：长按点「更多分类」打开面板 2 下，再在面板里选：预先选好的直接点「确定」1 下，在「建议」里 2 下，
    ///   在下面的分类格子里大类 2 下、小类 3 下（先点大类展开）
    static func taps(
        _ chosen: LedgerCategory, blank: LedgerRecord, suggestions: CategorySuggestions, learner: CategoryLearner, tree: CategoryTree
    ) throws -> Int {
        if let top = tree.topLevel(chosen.id), suggestions.topCategories.contains(top) {
            guard chosen.parentID != nil else { return 2 }
            var picked = blank
            picked.categoryID = top.id
            return try learner.subcategories(for: picked, tree: tree).contains(chosen) ? 4 : 5
        }
        if suggestions.preferredID == chosen.id { return 3 }
        if suggestions.categories.contains(chosen) { return 4 }
        return chosen.parentID == nil ? 4 : 5
    }
}
