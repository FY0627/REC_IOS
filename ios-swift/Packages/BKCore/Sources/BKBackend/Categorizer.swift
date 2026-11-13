import Foundation
import BKModel
import BKDatabase

/// 自动归类：自动记账入账后配上分类。
///
/// 1. 转帐不用分类（按交易性质对应到转帐分类，不保存）；
/// 2. 手续费、扣息、工资、利息：通知里写明了，直接归到对应的分类；
/// 3. 退款：跟着原来那笔的分类（从那个分类里减掉）；
/// 4. 同一个商户连续选过同一个分类：归到这个分类，流水标成自动归类（`CategoryLearner`，ADR 0017）；
///    先看这个时段连续选的；学到的是三餐之一时，换成这个时段的那一餐（ADR 0026）；
/// 5. 剩下的是「待分类」，由用户选。没确认对方的转账也是，不管选过什么。
///
/// 没学过的商户不猜（小词库只排推荐，`CategoryLexicon`）。所有函数都在 `Database.write` 的闭包里执行。
struct Categorizer {
    let db: SQLiteConnection
    let calendar: Calendar

    /// 入账后的自动归类；已经有分类的不动
    func categorize(recordID: String) throws {
        guard let record = try RecordDAO.find(db, id: recordID), record.status == .posted, record.categoryID == nil,
              !record.needsTransferConfirmation else { return }
        let tree = CategoryTree(try CategoryDAO.all(db))
        if let category = try category(for: record, tree: tree) {
            try RecordDAO.setCategory(db, ids: [record.id], categoryID: category.id)
        } else if let learned = try CategoryLearner(db: db, calendar: calendar).autoCategory(for: record, tree: tree) {
            try RecordDAO.setCategory(db, ids: [record.id], categoryID: learned.id, auto: true)
        }
    }

    func category(for record: LedgerRecord, tree: CategoryTree) throws -> LedgerCategory? {
        let type = record.entryType
        guard type != .transfer else { return nil }
        let wanted = CategoryType(type)
        let autoKey: String? = switch record.kind {
        case .fee where type == .expense: CategoryKey.fee
        case .interestCharge where type == .expense: CategoryKey.interestCharge
        case .salary where type == .income: CategoryKey.salary
        case .interestIncome where type == .income: CategoryKey.interestIncome
        default: nil
        }
        if let autoKey, let category = tree.category(autoKey: autoKey), category.type == wanted { return category }
        if record.isRefund, let originID = record.relatedRecordID, let origin = try RecordDAO.find(db, id: originID),
           let category = tree.category(origin.categoryID), category.type == wanted {
            return category
        }
        return nil
    }
}
