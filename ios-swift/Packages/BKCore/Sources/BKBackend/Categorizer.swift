import Foundation
import BKModel
import BKDatabase

/// 自动归类：自动记账入账后，只给通知里写明了是什么的流水配上分类，不猜。
///
/// 1. 转帐不用分类（按交易性质对应到转帐分类，不保存）；
/// 2. 手续费、扣息、工资、利息：通知里写明了，直接归到对应的分类；
/// 3. 退款：跟着原来那笔的分类（从那个分类里减掉）；
/// 4. 剩下的是「待分类」，由用户选。
///
/// 不按交易对方记住分类、不按时间猜三餐：先把识别和记账做可靠（ADR 0014 的修订）。
/// 所有函数都在 `Database.write` 的闭包里执行。
struct Categorizer {
    let db: SQLiteConnection

    /// 入账后的自动归类；已经有分类的不动
    func categorize(recordID: String) throws {
        guard let record = try RecordDAO.find(db, id: recordID), record.status == .posted, record.categoryID == nil,
              !record.needsTransferConfirmation else { return }
        guard let category = try category(for: record, tree: CategoryTree(try CategoryDAO.all(db))) else { return }
        try RecordDAO.setCategory(db, ids: [record.id], categoryID: category.id)
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
