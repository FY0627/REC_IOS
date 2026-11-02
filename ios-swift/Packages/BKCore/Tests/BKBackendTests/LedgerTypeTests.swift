import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 参考 MOZE 基础记账的部分：支出 / 收入 / 转帐、分类（通知写明的直接归类，学习归类见 `CategoryLearningTests`）、首页合并显示、手动记账、合成一单、
/// 按分类统计、换算成主要币种的本月合计、电子钱包自动记账。
final class LedgerTypeTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    @discardableResult
    func addAccount(
        _ backend: LedgerBackend, bank: String = "cmb", bankName: String = "招商银行", last4: String, type: CardType = .debit,
        currency: CurrencyCode = .cny, extras: [CurrencyCode] = [], opening: Int64? = nil
    ) async throws -> Account {
        try await backend.addAccount(AccountDraft(
            name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: currency, paletteID: "ocean",
            openingBalanceMinor: opening, extraCurrencies: extras
        ))
    }

    func ingest(_ backend: LedgerBackend, _ text: String, at date: Date? = nil) async throws {
        _ = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: date))
    }

    func category(_ backend: LedgerBackend, _ name: String, type: CategoryType = .expense) async throws -> LedgerCategory {
        let all = try await backend.categories()
        return try XCTUnwrap(all.first { $0.name == name && $0.type == type })
    }

    // MARK: 类型

    func testEntryTypesFollowKindDirectionAndTransfers() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "您尾号0427账户10月22日ATM取款500.00元，余额2,237.83元【招商银行】")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元。")
        try await ingest(backend, "您尾号0427账户10月24日15:00代发工资8,000.00元【招商银行】")
        let rows = try await backend.records()
        let types = Dictionary(uniqueKeysWithValues: rows.map { ($0.record.kind, $0.record.entryType) })
        XCTAssertEqual(types[.withdrawal], .transfer, "取现金是转帐，不算支出")
        XCTAssertEqual(types[.purchase], .expense)
        XCTAssertEqual(types[.salary], .income)

        let transfers = try await backend.records(filter: RecordFilter(entryType: .transfer))
        XCTAssertEqual(transfers.map(\.record.kind), [.withdrawal])
        XCTAssertEqual(transfers.first?.category?.name, "存取现金", "转帐按交易性质对应到转帐分类")
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 38_00)
        XCTAssertEqual(cny.incomeMinor, 8_000_00)
        XCTAssertEqual(cny.transferMinor, 500_00)
    }

    // MARK: 自动归类

    func testFeeSalaryAndInterestAreCategorizedAutomatically() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        try await ingest(backend, "您尾号6621账户10月24日15:00代发工资8,000.00元【工商银行】")
        let rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.kind == .fee }?.category?.name, "手续费")
        XCTAssertEqual(rows.first { $0.record.kind == .salary }?.category?.name, "工资")
        XCTAssertNil(rows.first { $0.record.kind == .transferOut }?.category, "转给谁不知道：待分类")
    }

    func testOnePickIsNotEnoughToCategorizeTheSameCounterparty() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "您尾号8810的信用卡10月20日12:10消费人民币25.00元，商户：财付通-美团。【中国银行】")
        try await ingest(backend, "您尾号8810的信用卡10月21日19:05消费人民币31.00元，商户：财付通-美团。【中国银行】")
        var waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.count, 2)

        let lunch = try await category(backend, "午餐")
        try await backend.setCategory(recordID: try XCTUnwrap(waiting.first { $0.record.amountMinor == 25_00 }?.id), categoryID: lunch.id, note: "牛肉面")
        waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.map(\.record.amountMinor), [31_00], "同一个对方的其他几笔不跟着归类")
        let rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.record.amountMinor == 25_00 }?.record.note, "牛肉面")

        try await ingest(backend, "您尾号8810的信用卡10月24日08:10消费人民币12.00元，商户：财付通-美团。【中国银行】")
        let count = try await backend.uncategorizedCount()
        XCTAssertEqual(count, 2, "只选过一次，新来的也留在待分类")
    }

    func testRefundFollowsOriginalCategoryAndReducesIt() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "您尾号8810的信用卡10月20日消费人民币99.00元，商户：京东商城。【中国银行】")
        let firstWaiting = try await backend.uncategorized()
        let original = try XCTUnwrap(firstWaiting.first)
        let clothes = try await category(backend, "衣着")
        try await backend.setCategory(recordID: original.id, categoryID: clothes.id)
        try await ingest(backend, "您尾号8810的信用卡收到退款人民币40.00元，商户：京东商城。【中国银行】")

        let rows = try await backend.records()
        let refund = try XCTUnwrap(rows.first { $0.record.kind == .refund })
        XCTAssertEqual(refund.record.entryType, .expense)
        XCTAssertTrue(refund.record.isRefund)
        XCTAssertEqual(refund.category?.id, clothes.id, "退款跟着原交易的分类")
        XCTAssertEqual(rows.first { $0.id == original.id }?.refundedMinor, 40_00)

        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.netExpenseMinor, 59_00)
        XCTAssertEqual(cny.incomeMinor, 0, "退款不算收入")
        XCTAssertEqual(cny.expenseCategories.first { $0.categoryID == clothes.id }?.amountMinor, 59_00)
    }

    func testUnconfirmedTransferIsCategorizedOrConfirmedAsOwn() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "您尾号0427账户10月20日10:00向张三转账500.00元【招商银行】")
        try await ingest(backend, "您尾号0427账户10月21日10:00向李四转账200.00元【招商银行】")
        let waiting = try await backend.uncategorized()
        XCTAssertEqual(waiting.count, 2, "没确认对方的转账也在待分类里")

        let gift = try await category(backend, "人情")
        let li = try XCTUnwrap(waiting.first { $0.record.counterparty == "李四" })
        try await backend.setCategory(recordID: li.id, categoryID: gift.id)
        let zhang = try XCTUnwrap(waiting.first { $0.record.counterparty == "张三" })
        try await backend.setTransferParty(recordID: zhang.id, party: .own)

        let rows = try await backend.records()
        XCTAssertEqual(rows.first { $0.id == li.id }?.record.transferParty, .other, "选了分类就是转给别人")
        XCTAssertEqual(rows.first { $0.id == zhang.id }?.record.entryType, .transfer)
        var count = try await backend.uncategorizedCount()
        XCTAssertEqual(count, 0)

        try await ingest(backend, "您尾号0427账户10月24日10:00向张三转账300.00元【招商银行】")
        count = try await backend.uncategorizedCount()
        XCTAssertEqual(count, 1, "不记住对方：下一笔还要确认")
    }

    // MARK: 首页合并显示

    func testFeedMergesTransferPairsFeesAndHidesFailedHolds() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】")
        try await ingest(backend, "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】")
        try await ingest(backend, "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        try await ingest(backend, "您尾号0427账户10月24日在苹果商店消费68.00元交易失败。【招商银行】")

        let all = try await backend.records()
        XCTAssertEqual(all.count, 5)
        let feed = try await backend.records(filter: RecordFilter(feed: true, mergeFees: true))
        XCTAssertEqual(feed.count, 2, "转帐两边一行、手续费合到那一笔、失败的不进首页")
        let pair = try XCTUnwrap(feed.first { $0.record.entryType == .transfer })
        XCTAssertEqual(pair.record.accountID, a.id, "留下转出那边")
        XCTAssertEqual(pair.peer?.text, "工商银行 ·6621")
        let remit = try XCTUnwrap(feed.first { $0.record.kind == .transferOut && $0.record.accountID == b.id })
        XCTAssertEqual(remit.feeMinor, 2_00)

        let detail = try await backend.records(filter: RecordFilter(accountID: b.id, mergeFees: true))
        XCTAssertEqual(detail.count, 2, "卡片详情里转入那边还在，手续费合并")
        let searched = try await backend.records(filter: RecordFilter(text: "转帐", feed: true))
        XCTAssertEqual(searched.count, 1, "按类型名称也能搜")
    }

    // MARK: 手动记账

    func testManualEntryExpenseAndCreditCardRepayment() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean", openingBalanceMinor: 500_00))
        let card = try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        let debit = try await addAccount(backend, last4: "0427")
        XCTAssertFalse(cash.isCard)
        XCTAssertEqual(cash.displayTitle, "现金")

        let snack = try await category(backend, "饮料零食")
        let time = now.addingTimeInterval(60)
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 15_00, currency: .cny, categoryID: snack.id, counterparty: "便利店", note: "可乐", time: time))
        let last = try await backend.lastManualAccountID()
        XCTAssertEqual(last, cash.id)
        let ids = try await backend.addRecord(ManualEntry(type: .transfer, accountID: debit.id, toAccountID: card.id, amountMinor: 300_00, currency: .cny, time: time))
        XCTAssertEqual(ids.count, 2)

        let rows = try await backend.records()
        let expense = try XCTUnwrap(rows.first { $0.record.accountID == cash.id })
        XCTAssertEqual(expense.record.source, .manual)
        XCTAssertEqual(expense.category?.id, snack.id)
        XCTAssertEqual(expense.record.note, "可乐")
        let repayments = rows.filter { $0.record.kind == .repayment }
        XCTAssertEqual(repayments.count, 2, "转进信用卡算还款")
        XCTAssertTrue(repayments.allSatisfy { $0.record.entryType == .transfer && $0.record.transferGroupID != nil })

        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[cash.id]?.primary?.ledgerDerivedMinor, 485_00)
        let log = try await backend.ingestLog()
        XCTAssertTrue(log.isEmpty, "手动记账不进接收日志")

        // 现金没有卡号：通知里的「0000」不会对上它
        _ = try await backend.ingest(IngestRequest(text: "您尾号0000账户10月24日消费10.00元【招商银行】", source: .sms))
        let cashRows = try await backend.records(accountID: cash.id)
        XCTAssertEqual(cashRows.count, 1)
    }

    func testBankMessageAfterManualEntryAsksIfSame() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        let entry = ManualEntry(type: .expense, accountID: account.id, amountMinor: 38_00, currency: .cny, note: "咖啡", time: now.addingTimeInterval(-3600))
        try await backend.addRecord(entry)
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0427的储蓄卡于10月24日15:58在星巴克咖啡消费人民币38.00元。", source: .sms, receivedAt: now))
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .possibleDuplicate, "手动记过的不再记一次，问是不是同一笔")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)

        let similar = try await backend.similarRecords(to: entry)
        XCTAssertEqual(similar.count, 1, "手动记之前也能查到已有的一笔")
    }

    // MARK: 合成一单

    func testOrderPaidWithTwoCardsMergesIntoOneRow() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在京东消费人民币700.00元。", at: now)
        try await ingest(backend, "您尾号8810的信用卡10月24日14:31消费人民币300.00元，商户：京东商城。【中国银行】", at: now.addingTimeInterval(60))
        let rows = try await backend.records()
        let first = try XCTUnwrap(rows.first { $0.record.amountMinor == 700_00 })
        let candidates = try await backend.orderCandidates(recordID: first.id)
        let second = try XCTUnwrap(candidates.first)
        XCTAssertEqual(second.record.amountMinor, 300_00)
        XCTAssertTrue(LedgerBackend.likelySameOrder(first.record, second.record))

        let home = try await category(backend, "日用品")
        try await backend.setCategory(recordID: first.id, categoryID: home.id)
        try await backend.mergeOrder(recordIDs: [first.id, second.id])
        var feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed[0].orderTotalMinor, 1_000_00)
        XCTAssertEqual(feed[0].orderParts.count, 2)
        XCTAssertEqual(feed[0].category?.id, home.id, "分类统一成一个")
        let detail = try await backend.recordDetail(id: feed[0].id)
        XCTAssertEqual(detail.orderMembers.count, 1)

        try await backend.splitOrder(recordIDs: [first.id])
        feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 2)
        XCTAssertTrue(feed.allSatisfy { $0.category?.id == home.id }, "拆开后分类保留")
    }

    func testSplittingLeavesTheRestOfTheOrderTogether() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0001")
        let b = try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "0002")
        let c = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "0003")
        var ids: [String] = []
        for (index, account) in [a, b, c].enumerated() {
            ids += try await backend.addRecord(ManualEntry(
                type: .expense, accountID: account.id, amountMinor: Int64(index + 1) * 100_00, currency: .cny, time: now.addingTimeInterval(Double(index))
            ))
        }
        try await backend.mergeOrder(recordIDs: ids)

        try await backend.splitOrder(recordIDs: [ids[0]])
        var feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 2, "拆出去的单独一行，另外两笔还是一单")
        let order = try XCTUnwrap(feed.first { !$0.orderParts.isEmpty })
        XCTAssertEqual(order.orderTotalMinor, 500_00)
        let alone = try XCTUnwrap(feed.first { $0.orderParts.isEmpty })
        XCTAssertEqual(alone.id, ids[0])

        try await backend.splitOrder(recordIDs: [ids[1]])
        feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 3, "只剩一笔，不再是一单")
        XCTAssertTrue(feed.allSatisfy { $0.record.orderGroupID == nil })
    }

    // MARK: 分类管理

    func testCategoriesCanBeEditedAndDeletingMovesRecords() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在宠物店消费人民币88.00元。")
        let pets = try await backend.addCategory(CategoryDraft(type: .expense, parentID: nil, name: " 宠物 ", symbol: "pawprint"))
        XCTAssertEqual(pets.name, "宠物")
        let food = try await backend.addCategory(CategoryDraft(type: .expense, parentID: pets.id, name: "猫粮", symbol: "pawprint"))
        do {
            _ = try await backend.addCategory(CategoryDraft(type: .expense, parentID: food.id, name: "第三层", symbol: "tag"))
            XCTFail("最多两层")
        } catch BackendError.invalidCategory {}

        let waiting = try await backend.uncategorized()
        let record = try XCTUnwrap(waiting.first)
        try await backend.setCategory(recordID: record.id, categoryID: food.id)
        try await backend.updateCategory(id: food.id, name: "猫粮和猫砂", symbol: "cart")
        var row = try await backend.records().first
        XCTAssertEqual(row?.category?.fullName, "宠物 · 猫粮和猫砂")

        try await backend.deleteCategory(id: pets.id, moveRecordsTo: nil)
        row = try await backend.records().first
        XCTAssertNil(row?.category, "删除分类：记录回到待分类，不删记录")
        let categories = try await backend.categories()
        XCTAssertFalse(categories.contains { $0.id == pets.id || $0.id == food.id })

        let fee = try await category(backend, "手续费")
        do {
            try await backend.deleteCategory(id: fee.id, moveRecordsTo: nil)
            XCTFail("系统分类不能删")
        } catch BackendError.categoryLocked {}
        try await backend.updateCategory(id: fee.id, name: "银行手续费", symbol: "doc.text")
    }

    func testMergeCategoryMovesRecords() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在健身房消费人民币200.00元。")
        let sport = try await category(backend, "运动")
        let waiting = try await backend.uncategorized()
        let record = try XCTUnwrap(waiting.first)
        try await backend.setCategory(recordID: record.id, categoryID: sport.id)
        let fun = try await category(backend, "娱乐")
        try await backend.mergeCategory(id: sport.id, into: fun.id)
        let row = try await backend.records().first
        XCTAssertEqual(row?.category?.id, fun.id)
        let categories = try await backend.categories()
        XCTAssertFalse(categories.contains { $0.id == sport.id })
    }

    func testStatsGroupByTopLevelCategory() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        let rent = try await category(backend, "房租")
        for (amount, id) in [(20_00, lunch.id), (30_00, dinner.id), (2_000_00, rent.id)] as [(Int64, String)] {
            try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: amount, currency: .cny, categoryID: id, time: now))
        }
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 5_00, currency: .cny, time: now))
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseCategories.map(\.name), ["居住", "饮食", "待分类"])
        let food = try XCTUnwrap(cny.expenseCategories.first { $0.name == "饮食" })
        XCTAssertEqual(food.amountMinor, 50_00)
        XCTAssertEqual(food.children.map(\.name), ["晚餐", "午餐"])
        let filtered = try await backend.records(filter: RecordFilter(categoryID: try XCTUnwrap(food.categoryID)))
        XCTAssertEqual(filtered.count, 2, "按大类查包括它的小类")
    }

    func testEditingTypeChangesKindAndKeepsCategoryConsistent() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        try await ingest(backend, "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元。")
        let all = try await backend.records()
        let row = try XCTUnwrap(all.first)
        let snack = try await category(backend, "饮料零食")
        try await backend.setCategory(recordID: row.id, categoryID: snack.id)

        var fields = RecordEdit.fields(for: .expense, refund: true, transferDirection: .outflow, original: row.record)
        XCTAssertEqual(fields.kind, .refund)
        XCTAssertEqual(fields.direction, .inflow)
        fields = RecordEdit.fields(for: .transfer, refund: false, transferDirection: .outflow, original: row.record)
        XCTAssertEqual(fields.kind, .transferOut)
        XCTAssertEqual(fields.party, .own)
        try await backend.updateRecord(id: row.id, RecordEdit(
            accountID: row.record.accountID, amountMinor: 38_00, currency: .cny, direction: fields.direction, kind: fields.kind,
            counterparty: row.record.counterparty, time: nil, note: "", transferParty: fields.party
        ))
        let after = try await backend.records()
        let updated = try XCTUnwrap(after.first)
        XCTAssertEqual(updated.record.entryType, .transfer)
        XCTAssertNil(updated.record.categoryID, "转帐不保存分类")
    }

    // MARK: 编辑转帐的另一边

    func testEditingTransferPeerMovesOrLinksTheOtherSide() async throws {
        let backend = try makeBackend()
        let debit = try await addAccount(backend, last4: "0427")
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean", openingBalanceMinor: 0))
        let wallet = try await backend.addAccount(.pocket(name: "零钱", type: .wallet, currency: .cny, paletteID: "jade", openingBalanceMinor: 0))
        let ids = try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: debit.id, toAccountID: cash.id, amountMinor: 100_00, currency: .cny, time: now.addingTimeInterval(60)
        ))
        let outRows = try await backend.records(accountID: debit.id)
        let out = try XCTUnwrap(outRows.first)
        XCTAssertEqual(out.id, ids[0])

        // 另一边换成电子钱包：现金那笔删掉，钱包补记一笔
        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: debit.id, amountMinor: 120_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: "", transferParty: .own, peer: .account(wallet.id)
        ))
        var balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[cash.id]?.primary?.ledgerDerivedMinor, 0, "原来补记在现金的那笔删掉了")
        XCTAssertEqual(balances[wallet.id]?.primary?.ledgerDerivedMinor, 120_00)
        let detail = try await backend.recordDetail(id: out.id)
        XCTAssertEqual(detail.transferPeer?.record.accountID, wallet.id)

        // 只改金额：补记的另一边跟着改，仍是一对
        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: debit.id, amountMinor: 150_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: ""
        ))
        balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[wallet.id]?.primary?.ledgerDerivedMinor, 150_00)
        let feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 1, "仍然合成一行")

        // 对方是没添加到 App 的账户：不配对，钱包那笔删掉
        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: debit.id, amountMinor: 150_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: "", peer: .untracked
        ))
        balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[wallet.id]?.primary?.ledgerDerivedMinor, 0)
        let aloneRows = try await backend.records(accountID: debit.id)
        let alone = try XCTUnwrap(aloneRows.first)
        XCTAssertEqual(alone.record.entryType, .transfer)
        XCTAssertNil(alone.record.transferGroupID)
    }

    func testEditingTransferPeerLinksExistingBankRecord() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号0427账户10月24日10:00向张三转账500.00元【招商银行】", at: now.addingTimeInterval(-4 * 3600))
        try await ingest(backend, "您尾号6621账户10月24日14:00转入500.00元【工商银行】", at: now)
        let outRows = try await backend.records(accountID: a.id)
        let out = try XCTUnwrap(outRows.first)
        XCTAssertNil(out.record.transferGroupID, "隔了四个小时，自动配对不上")
        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: a.id, amountMinor: 500_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: out.record.counterparty, time: nil, note: "", transferParty: .own, peer: .account(b.id)
        ))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2, "那边已经有银行记的一笔：配成一对，不补记")
        let detail = try await backend.recordDetail(id: out.id)
        XCTAssertEqual(detail.transferPeer?.record.accountID, b.id)
    }

    // MARK: 转帐到账多少

    func testTransferWithFeeArrivesLessAndIsNotAnExpense() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0001", opening: 2_000_00)
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "0002", opening: 0)
        let time = now.addingTimeInterval(60)
        try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: a.id, toAccountID: b.id, amountMinor: 1_000_00, currency: .cny, toAmountMinor: 998_00, time: time
        ))
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[a.id]?.primary?.ledgerDerivedMinor, 1_000_00)
        XCTAssertEqual(balances[b.id]?.primary?.ledgerDerivedMinor, 998_00, "到账比转出少")

        let feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 1, "两边合成一行")
        XCTAssertEqual(feed[0].record.amountMinor, 1_000_00)
        XCTAssertEqual(feed[0].peerMoney, Money(minorUnits: 998_00, currency: .cny))
        XCTAssertEqual(feed[0].record.entryType, .transfer)

        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor ?? 0, 0, "差额只影响余额，不算支出")
        XCTAssertEqual(stats.currencies.first?.incomeMinor ?? 0, 0)
    }

    func testExchangeWithinOneAccountMovesMoneyBetweenCurrencies() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, bank: "hangseng", bankName: "恒生银行", last4: "0004", currency: .hkd, extras: [.cny], opening: 1_000_00)
        try await backend.setOpeningBalance(accountID: card.id, currency: .cny, amountMinor: 0)
        let time = now.addingTimeInterval(60)
        try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: card.id, toAccountID: card.id, amountMinor: 100_00, currency: .hkd,
            toAmountMinor: 91_00, toCurrency: .cny, time: time
        ))
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[card.id]?.item(.hkd)?.ledgerDerivedMinor, 900_00)
        XCTAssertEqual(balances[card.id]?.item(.cny)?.ledgerDerivedMinor, 91_00)
        let feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed[0].peer?.text, feed[0].account.text, "两边是同一个账户")
        XCTAssertEqual(feed[0].peerMoney, Money(minorUnits: 91_00, currency: .cny))

        do {
            try await backend.addRecord(ManualEntry(type: .transfer, accountID: card.id, toAccountID: card.id, amountMinor: 1_00, currency: .hkd, time: time))
            XCTFail("同一个账户的同一个币种不是转帐")
        } catch BackendError.invalidTransfer {}
    }

    func testExchangeOnACreditCardIsNotARepayment() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, last4: "0005", type: .credit, currency: .cny, extras: [.usd])
        let ids = try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: card.id, toAccountID: card.id, amountMinor: 700_00, currency: .cny, toAmountMinor: 95_00, toCurrency: .usd, time: now
        ))
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.count, ids.count)
        XCTAssertTrue(rows.allSatisfy { $0.record.kind != .repayment })
    }

    func testEditingWhatArrivedKeepsTheTransferPaired() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0001", opening: 0)
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "0002", opening: 0)
        let ids = try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: a.id, toAccountID: b.id, amountMinor: 100_00, currency: .cny, time: now.addingTimeInterval(60)
        ))
        try await backend.updateRecord(id: ids[0], RecordEdit(
            accountID: a.id, amountMinor: 100_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: "", peerAmountMinor: 97_00, peerCurrency: .cny
        ))
        var detail = try await backend.recordDetail(id: ids[0])
        XCTAssertEqual(detail.transferPeer?.record.amountMinor, 97_00)
        var balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[b.id]?.primary?.ledgerDerivedMinor, 97_00)

        // 到账已经和转出不一样：只改备注时另一边不动
        try await backend.updateRecord(id: ids[0], RecordEdit(
            accountID: a.id, amountMinor: 100_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: "手续费 3 块"
        ))
        detail = try await backend.recordDetail(id: ids[0])
        XCTAssertEqual(detail.transferPeer?.record.amountMinor, 97_00)
        balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[b.id]?.primary?.ledgerDerivedMinor, 97_00)
    }

    func testBankRecordsThatDifferByAFeeCanBePaired() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        try await ingest(backend, "您尾号0427账户10月24日10:00向张三转账500.00元【招商银行】", at: now.addingTimeInterval(-3600))
        try await ingest(backend, "您尾号6621账户10月24日14:00转入498.00元【工商银行】", at: now)
        let outRows = try await backend.records(accountID: a.id)
        let out = try XCTUnwrap(outRows.first)
        XCTAssertNil(out.record.transferGroupID, "金额不一样，自动配对不上")

        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: a.id, amountMinor: 500_00, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: out.record.counterparty, time: nil, note: "", transferParty: .own, peer: .account(b.id),
            peerAmountMinor: 498_00, peerCurrency: .cny
        ))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2, "那边银行记的一笔配成一对，不补记")
        var detail = try await backend.recordDetail(id: out.id)
        XCTAssertEqual(detail.transferPeer?.record.accountID, b.id)
        XCTAssertEqual(detail.row.peerMoney, Money(minorUnits: 498_00, currency: .cny))

        // 银行记的另一边：填了到账多少时改它，仍是一对
        try await backend.updateRecord(id: out.id, RecordEdit(
            accountID: a.id, amountMinor: 500_00, currency: .cny, direction: .outflow, kind: out.record.kind,
            counterparty: out.record.counterparty, time: nil, note: "", transferParty: .own, peerAmountMinor: 495_00, peerCurrency: .cny
        ))
        detail = try await backend.recordDetail(id: out.id)
        XCTAssertEqual(detail.transferPeer?.record.amountMinor, 495_00)
    }

    func testManualEntryInACurrencyTheAccountLacksIsChargedInItsMainCurrency() async throws {
        let backend = try makeBackend()
        let cny = try await addAccount(backend, last4: "0427")
        let hkd = try await backend.addAccount(AccountDraft(
            name: "", bankID: "hangseng", bankName: "恒生银行", last4: "0104", cardType: .debit, currency: .hkd, paletteID: "jade"
        ))
        try await backend.saveExchangeRates(ExchangeRates(base: .usd, rates: ["USD": 1, "HKD": 7.8, "CNY": 7.2, "JPY": 150], updatedAt: now, fetchedAt: now))

        // 先选币种再选账户：卡里没有日元也能记，不填实际扣款就按汇率估算
        let estimate = try await backend.estimateCharge(amountMinor: 1_000, currency: .jpy, to: .cny, at: now)
        XCTAssertEqual(estimate.amountMinor, 48_00, "1000 日元 = 6.67 美元 = 48 人民币")
        XCTAssertEqual(estimate.rateDay, RateDay.key(now, calendar: calendar))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cny.id, amountMinor: 1_000, currency: .jpy, time: now))
        var rows = try await backend.records(accountID: cny.id)
        XCTAssertEqual(rows.first?.record.currency, .jpy)
        XCTAssertNil(rows.first?.record.settlement)
        XCTAssertEqual(rows.first?.charge?.amountMinor, 48_00)
        XCTAssertEqual(rows.first?.charge?.isActual, false)

        // 填了实际扣款就用它
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: cny.id, amountMinor: 2_000, currency: .jpy, time: now.addingTimeInterval(60), settlementMinor: 95_10
        ))
        rows = try await backend.records(accountID: cny.id)
        XCTAssertEqual(rows.first?.record.settlement, Money(minorUnits: 95_10, currency: .cny))
        XCTAssertEqual(rows.first?.charge?.isActual, true)

        // 转帐：转出的账户没有日元就按主币种扣款，到账写实际到了多少港币
        let ids = try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: cny.id, toAccountID: hkd.id, amountMinor: 10_000, currency: .jpy,
            toAmountMinor: 520_00, toCurrency: .hkd, time: now.addingTimeInterval(120), settlementMinor: 480_00
        ))
        XCTAssertEqual(ids.count, 2)
        let out = try await backend.records(accountID: cny.id).first { $0.record.amountMinor == 10_000 }
        XCTAssertEqual(out?.record.settlement, Money(minorUnits: 480_00, currency: .cny))
        let into = try await backend.records(accountID: hkd.id).first
        XCTAssertEqual(into?.record.money, Money(minorUnits: 520_00, currency: .hkd))
        XCTAssertNil(into?.record.settlement)
        XCTAssertEqual(into?.record.direction, .inflow)

        // 账户有这个币种：不存实际扣款
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: hkd.id, amountMinor: 50_00, currency: .hkd, time: now.addingTimeInterval(180), settlementMinor: 1
        ))
        let plain = try await backend.records(accountID: hkd.id).first { $0.record.amountMinor == 50_00 }
        XCTAssertNil(plain?.record.settlement)
    }

    func testStatsForAPeriodCoverEveryMonthInIt() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 30_00, currency: .cny, time: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 20_00, currency: .cny, time: lastMonth))
        let month = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(month.currencies.first?.expenseMinor, 30_00)
        let all = try await backend.stats(from: nil, to: nil)
        XCTAssertEqual(all.currencies.first?.expenseMinor, 50_00, "「全部」包括上个月的")
        XCTAssertEqual(all.accounts.first?.outflowMinor, 50_00)
        let since = try await backend.stats(from: lastMonth, to: nil)
        XCTAssertEqual(since.currencies.first?.expenseMinor, 50_00)
    }

    // MARK: 换算成主要币种

    func testMonthTotalsConvertedToPrimaryCurrency() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let hk = try await backend.addAccount(.pocket(name: "港币现金", type: .cash, currency: .hkd, paletteID: "ocean"))
        let yen = try await backend.addAccount(.pocket(name: "日元现金", type: .cash, currency: .jpy, paletteID: "ocean"))
        try await backend.saveExchangeRates(ExchangeRates(base: .usd, rates: ["USD": 1, "HKD": 7.8, "CNY": 7.2], updatedAt: now, fetchedAt: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 100_00, currency: .cny, time: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: hk.id, amountMinor: 78_00, currency: .hkd, time: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: hk.id, amountMinor: 7_80, currency: .hkd, isRefund: true, time: now))
        try await backend.addRecord(ManualEntry(type: .income, accountID: cash.id, amountMinor: 1_000_00, currency: .cny, time: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: yen.id, amountMinor: 500, currency: .jpy, time: now))
        let stats = try await backend.monthStats(year: 2026, month: 10, convertTo: .cny)
        let total = try XCTUnwrap(stats.converted)
        XCTAssertEqual(total.expenseMinor, 100_00 + 72_00 - 7_20, "港币按汇率换算，退款减掉")
        XCTAssertEqual(total.incomeMinor, 1_000_00)
        XCTAssertEqual(total.balanceMinor, 1_000_00 - 164_80)
        XCTAssertEqual(total.unconverted, [.jpy], "没有日元汇率：不计入，单独列出")
        XCTAssertEqual(total.expenseCategories.map(\.amountMinor).reduce(0, +), total.expenseMinor, "分类也按换算后的金额，加起来等于支出")
        XCTAssertEqual(total.expenseCategories.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(total.incomeCategories.map(\.amountMinor), [1_000_00])

        // 只看一个账户
        let hkOnly = try await backend.stats(from: nil, to: nil, convertTo: .cny, accountID: hk.id)
        XCTAssertEqual(hkOnly.currencies.map(\.currency), [.hkd])
        XCTAssertEqual(hkOnly.currencies.first?.netExpenseMinor, 78_00 - 7_80)
        XCTAssertEqual(hkOnly.currencies.first?.expenseCategories.map(\.amountMinor), [78_00 - 7_80])
        XCTAssertEqual(hkOnly.converted?.expenseMinor, 72_00 - 7_20)
        XCTAssertEqual(hkOnly.accounts.map(\.accountID), [hk.id])
    }

    // MARK: 电子钱包自动记账

    func testWalletNotificationIsRecordedToTheWalletAccount() async throws {
        let backend = try makeBackend()
        let alipay = try await backend.addAccount(.pocket(name: "支付宝余额", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
        let card = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "【支付宝】你于10月24日12:30在瑞幸咖啡消费25.00元。", source: .notification))
        var rows = try await backend.records(accountID: alipay.id)
        XCTAssertEqual(rows.map(\.record.amountMinor), [25_00], "没写卡号：记到唯一的支付宝账户")

        // 写了卡号尾号的是用银行卡付的，记到卡上
        _ = try await backend.ingest(IngestRequest(text: "【支付宝】你尾号0427的储蓄卡于10月24日13:30在瑞幸咖啡消费18.00元。", source: .notification))
        rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.map(\.record.amountMinor), [18_00])

        // 有小号：让用户选
        let second = try await backend.addAccount(.pocket(name: "支付宝小号", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
        _ = try await backend.ingest(IngestRequest(text: "【支付宝】你于10月24日14:30在全家消费9.90元。", source: .notification))
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .ambiguousAccount)
        XCTAssertEqual(Set(pending.first?.candidateAccountIDs ?? []), [alipay.id, second.id])
        try await backend.confirmPending(id: try XCTUnwrap(pending.first?.id), accountID: second.id)
        rows = try await backend.records(accountID: second.id)
        XCTAssertEqual(rows.map(\.record.amountMinor), [9_90])
    }

    func testWalletIsGuessedFromAccountNameAndBankMessagesMentioningWalletsStayOnCards() async throws {
        let backend = try makeBackend()
        // 以前添加的电子钱包没有选是哪个钱包：按名称认
        let wechat = try await backend.addAccount(.pocket(name: "微信零钱", type: .wallet, currency: .cny, paletteID: "jade"))
        XCTAssertEqual(WalletDirectory.provider(of: wechat), "wechatpay")
        _ = try await backend.ingest(IngestRequest(text: "微信支付 你于10月24日12:30在美团消费25.00元", source: .notification))
        let rows = try await backend.records(accountID: wechat.id)
        XCTAssertEqual(rows.count, 1)

        // 银行短信里提到财付通：不是钱包发的
        XCTAssertNil(WalletDirectory.identify(sender: "95555", text: "【招商银行】您尾号0427的储蓄卡于10月24日在财付通-美团消费人民币20.00元。"))
        XCTAssertEqual(WalletDirectory.identify(sender: "95188", text: "你有一笔支出"), "alipay")
    }
}
