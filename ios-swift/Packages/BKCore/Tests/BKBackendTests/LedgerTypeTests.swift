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

    /// 自己记的退款（或者通知没写商户、找不到唯一原交易的）可以手动关联到原交易，两边都能发起，也能取消
    func testRefundCanBeLinkedToOriginalByHand() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let wallet = try await backend.addAccount(.pocket(name: "零钱", type: .wallet, currency: .cny, paletteID: "ocean"))
        let clothes = try await category(backend, "衣着")
        let earlier = now.addingTimeInterval(-3 * 86_400)
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 99_00, currency: .cny, categoryID: clothes.id, time: earlier))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 20_00, currency: .cny, time: earlier))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: wallet.id, amountMinor: 40_00, currency: .cny, isRefund: true, time: now))
        let rows = try await backend.records()
        let original = try XCTUnwrap(rows.first { $0.record.amountMinor == 99_00 })
        let refund = try XCTUnwrap(rows.first { $0.record.isRefund })
        XCTAssertNil(refund.record.relatedRecordID, "自己记的退款不会自动关联")

        // 从退款这边找原交易：金额够退的支出，退到别的账户也算；20 元的不够退 40 元
        let origins = try await backend.refundLinkCandidates(recordID: refund.id)
        XCTAssertEqual(origins.map(\.id), [original.id])
        try await backend.linkRefunds([refund.id], to: original.id)
        var detail = try await backend.recordDetail(id: original.id)
        XCTAssertEqual(detail.refunds.map(\.id), [refund.id])
        XCTAssertEqual(detail.row.refundedMinor, 40_00, "原交易下面写已退")
        detail = try await backend.recordDetail(id: refund.id)
        XCTAssertEqual(detail.related?.id, original.id)
        XCTAssertEqual(detail.row.category?.id, clothes.id, "退款跟着原交易的分类")
        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseCategories.first { $0.categoryID == clothes.id }?.amountMinor, 59_00, "统计里从同一个分类减掉")

        // 关联好的退款不再出现在原交易那边的候选里；取消后又出现
        var refunds = try await backend.refundLinkCandidates(recordID: original.id)
        XCTAssertTrue(refunds.isEmpty)
        try await backend.unlinkRefund(refund.id)
        detail = try await backend.recordDetail(id: original.id)
        XCTAssertTrue(detail.refunds.isEmpty)
        XCTAssertNil(detail.row.refundedMinor)
        refunds = try await backend.refundLinkCandidates(recordID: original.id)
        XCTAssertEqual(refunds.map(\.id), [refund.id])

        // 从支出这边关联退款
        try await backend.linkRefunds(refunds.map(\.id), to: original.id)
        detail = try await backend.recordDetail(id: refund.id)
        XCTAssertEqual(detail.related?.id, original.id)

        // 收入不能当原交易，支出不能当退款
        try await backend.addRecord(ManualEntry(type: .income, accountID: cash.id, amountMinor: 500_00, currency: .cny, time: earlier))
        let income = try await backend.records().first { $0.record.entryType == .income }
        do {
            try await backend.linkRefunds([refund.id], to: try XCTUnwrap(income).id)
            XCTFail("收入不能当原交易")
        } catch {
            XCTAssertEqual(error as? BackendError, .invalidRefund)
        }
        do {
            try await backend.linkRefunds([original.id], to: original.id)
            XCTFail("支出不能当退款")
        } catch {
            XCTAssertEqual(error as? BackendError, .invalidRefund)
        }
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

    // MARK: 一笔支出和另一个账户的一笔收入合成转帐

    /// 微信提现 10 元到中行卡：微信那边手动记了支出 10.10（含手续费），中行短信记成了收入 10.00
    struct Withdrawal {
        let wechat: Account
        let boc: Account
        let spendID: String
        let incomeID: String
    }

    func withdrawal(_ backend: LedgerBackend) async throws -> Withdrawal {
        let wechat = try await backend.addAccount(.pocket(name: "微信零钱", type: .wallet, currency: .cny, paletteID: "jade", openingBalanceMinor: 100_00))
        let boc = try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "0001", opening: 100_00)
        let other = try await category(backend, "其他")
        let spendID = try await backend.addRecord(ManualEntry(
            type: .expense, accountID: wechat.id, amountMinor: 10_10, currency: .cny, categoryID: other.id, time: now.addingTimeInterval(-300)
        ))[0]
        try await ingest(backend, "您的借记卡账户0001，于10月24日网上支付收入人民币10.00元,交易后余额110.00【中国银行】", at: now)
        let income = try await backend.records(accountID: boc.id)
        return Withdrawal(wechat: wechat, boc: boc, spendID: spendID, incomeID: try XCTUnwrap(income.first).id)
    }

    func testExpenseAndIncomeOfTwoAccountsMergeIntoTransferAndSplitBack() async throws {
        let backend = try makeBackend()
        let w = try await withdrawal(backend)
        let other = try await category(backend, "其他")
        var stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor, 10_10)
        XCTAssertEqual(stats.currencies.first?.incomeMinor, 10_00)
        let balancesBefore = try await backend.balanceSummaries()

        let candidates = try await backend.transferMergeCandidates(recordID: w.spendID)
        XCTAssertEqual(candidates.map(\.id), [w.incomeID], "别的账户、方向相反的那一笔")
        let back = try await backend.transferMergeCandidates(recordID: w.incomeID)
        XCTAssertEqual(back.map(\.id), [w.spendID])

        try await backend.mergeTransfer(recordID: w.spendID, with: w.incomeID)
        stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 0, "不再算支出")
        XCTAssertEqual(cny.incomeMinor, 0, "不再算收入")
        XCTAssertEqual(cny.transferMinor, 10_10, "转帐只算转出那边")
        let balancesAfter = try await backend.balanceSummaries()
        XCTAssertEqual(balancesAfter[w.wechat.id]?.primary?.ledgerDerivedMinor, balancesBefore[w.wechat.id]?.primary?.ledgerDerivedMinor)
        XCTAssertEqual(balancesAfter[w.boc.id]?.primary?.ledgerDerivedMinor, balancesBefore[w.boc.id]?.primary?.ledgerDerivedMinor)

        let feed = try await backend.records(filter: RecordFilter(feed: true))
        XCTAssertEqual(feed.map(\.id), [w.spendID], "首页合成一行，只留转出那边")
        XCTAssertEqual(feed[0].record.entryType, .transfer)
        XCTAssertEqual(feed[0].peer?.text, "中国银行 ·0001")
        XCTAssertEqual(feed[0].peerMoney, Money(minorUnits: 10_00, currency: .cny), "到账金额不变，差额是手续费")
        XCTAssertEqual(feed[0].category?.name, "转帐")
        let waiting = try await backend.uncategorized()
        XCTAssertTrue(waiting.isEmpty, "转帐不用分类")
        let detail = try await backend.recordDetail(id: w.incomeID)
        XCTAssertTrue(detail.mergedTransfer)
        XCTAssertEqual(detail.transferPeer?.id, w.spendID)
        XCTAssertEqual(detail.evidence.map(\.source), [.sms], "银行短信留着")
        let none = try await backend.transferMergeCandidates(recordID: w.spendID)
        XCTAssertTrue(none.isEmpty, "已经是转帐了")

        try await backend.splitTransfer(recordID: w.incomeID)
        let spend = try await backend.recordDetail(id: w.spendID)
        XCTAssertFalse(spend.mergedTransfer)
        XCTAssertEqual(spend.row.record.kind, .purchase)
        XCTAssertEqual(spend.row.record.entryType, .expense)
        XCTAssertEqual(spend.row.record.categoryID, other.id, "拆开回到原来的分类")
        XCTAssertNil(spend.row.record.transferGroupID)
        let income = try await backend.recordDetail(id: w.incomeID)
        XCTAssertEqual(income.row.record.kind, .other)
        XCTAssertEqual(income.row.record.entryType, .income)
        XCTAssertNil(income.row.record.categoryID)
        stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor, 10_10)
        XCTAssertEqual(stats.currencies.first?.incomeMinor, 10_00)
        let again = try await backend.uncategorized()
        XCTAssertEqual(again.map(\.id), [w.incomeID])
        do {
            try await backend.splitTransfer(recordID: w.incomeID)
            XCTFail("已经拆开了")
        } catch BackendError.invalidTransfer {}
    }

    func testMergingIntoTransferNeedsOneExpenseAndOneIncomeOfDifferentAccounts() async throws {
        let backend = try makeBackend()
        let w = try await withdrawal(backend)
        let credit = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "8810", type: .credit)
        let ids = try await backend.addRecord(ManualEntry(type: .expense, accountID: w.boc.id, amountMinor: 5_00, currency: .cny, time: now))
        let refund = try await backend.addRecord(ManualEntry(type: .expense, accountID: credit.id, amountMinor: 3_00, currency: .cny, isRefund: true, time: now))
        let paidBack = try await backend.addRecord(ManualEntry(type: .income, accountID: credit.id, amountMinor: 200_00, currency: .cny, time: now))
        for (a, b) in [(w.spendID, ids[0]), (w.incomeID, ids[0]), (w.spendID, refund[0])] {
            do {
                try await backend.mergeTransfer(recordID: a, with: b)
                XCTFail("两笔支出、同一个账户、退款都不行")
            } catch BackendError.invalidTransfer {}
        }

        // 转进信用卡算还款
        try await backend.mergeTransfer(recordID: paidBack[0], with: ids[0])
        let detail = try await backend.recordDetail(id: ids[0])
        XCTAssertEqual(detail.row.record.kind, .repayment)
        XCTAssertEqual(detail.row.category?.name, "还信用卡")
        do {
            try await backend.mergeTransfer(recordID: w.spendID, with: paidBack[0])
            XCTFail("已经是转帐的不能再合")
        } catch BackendError.invalidTransfer {}
    }

    func testBreakingUpAMergedTransferNeverDeletesEitherSide() async throws {
        let backend = try makeBackend()
        let w = try await withdrawal(backend)
        let other = try await category(backend, "其他")

        // 删掉银行那边：微信那笔回到原来的支出
        try await backend.mergeTransfer(recordID: w.spendID, with: w.incomeID)
        try await backend.deleteRecord(id: w.incomeID)
        var spend = try await backend.recordDetail(id: w.spendID)
        XCTAssertEqual(spend.row.record.entryType, .expense)
        XCTAssertEqual(spend.row.record.categoryID, other.id)
        XCTAssertFalse(spend.mergedTransfer)

        // 银行那边改回收入：微信那笔是自己手动记的支出，不当成补记的另一边删掉，回到原来的支出
        let backend2 = try makeBackend()
        let second = try await withdrawal(backend2)
        try await backend2.mergeTransfer(recordID: second.spendID, with: second.incomeID)
        try await backend2.updateRecord(id: second.incomeID, RecordEdit(
            accountID: second.boc.id, amountMinor: 10_00, currency: .cny, direction: .inflow, kind: .income,
            counterparty: nil, time: nil, note: "", keepsCategory: false
        ))
        spend = try await backend2.recordDetail(id: second.spendID)
        XCTAssertEqual(spend.row.record.entryType, .expense)
        XCTAssertEqual(spend.row.record.categoryID, other.id)
        let income = try await backend2.recordDetail(id: second.incomeID)
        XCTAssertEqual(income.row.record.entryType, .income)
        XCTAssertFalse(income.mergedTransfer)

        // 银行那边换了另一边的账户：微信那笔回到支出，现金补记一笔
        let backend3 = try makeBackend()
        let third = try await withdrawal(backend3)
        let cash = try await backend3.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean", openingBalanceMinor: 0))
        try await backend3.mergeTransfer(recordID: third.spendID, with: third.incomeID)
        try await backend3.updateRecord(id: third.incomeID, RecordEdit(
            accountID: third.boc.id, amountMinor: 10_00, currency: .cny, direction: .inflow, kind: .transferIn,
            counterparty: nil, time: nil, note: "", keepsCategory: false, transferParty: .own, peer: .account(cash.id)
        ))
        spend = try await backend3.recordDetail(id: third.spendID)
        XCTAssertEqual(spend.row.record.entryType, .expense)
        XCTAssertEqual(spend.row.record.categoryID, other.id)
        let moved = try await backend3.recordDetail(id: third.incomeID)
        XCTAssertEqual(moved.transferPeer?.record.accountID, cash.id)
        XCTAssertFalse(moved.mergedTransfer, "换了另一边就是普通的转帐")
    }

    func testEditedMergedTransferStillSplitsBackWithEdits() async throws {
        let backend = try makeBackend()
        let w = try await withdrawal(backend)
        let other = try await category(backend, "其他")
        let daily = try await category(backend, "日用品")
        try await backend.mergeTransfer(recordID: w.spendID, with: w.incomeID)
        // 编辑页保存转帐：交易性质写成转出，另一边是银行记的，带上到账金额
        try await backend.updateRecord(id: w.spendID, RecordEdit(
            accountID: w.wechat.id, amountMinor: 10_10, currency: .cny, direction: .outflow, kind: .transferOut,
            counterparty: nil, time: nil, note: "微信提现", keepsCategory: false, transferParty: .own,
            peerAmountMinor: 10_00, peerCurrency: .cny
        ))
        var detail = try await backend.recordDetail(id: w.spendID)
        XCTAssertTrue(detail.mergedTransfer, "改备注还是一对，还能拆开")
        XCTAssertEqual(detail.transferPeer?.id, w.incomeID)
        // 改银行那边的时间：微信那笔是自己记的，不跟着改时间
        try await backend.updateRecord(id: w.incomeID, RecordEdit(
            accountID: w.boc.id, amountMinor: 10_00, currency: .cny, direction: .inflow, kind: .transferIn,
            counterparty: nil, time: now.addingTimeInterval(600), note: "", keepsCategory: false, transferParty: .own,
            peerAmountMinor: 10_10, peerCurrency: .cny
        ))
        detail = try await backend.recordDetail(id: w.spendID)
        XCTAssertTrue(detail.mergedTransfer)
        XCTAssertEqual(detail.row.record.effectiveAt, now.addingTimeInterval(-300))
        XCTAssertEqual(detail.row.record.amountMinor, 10_10)

        // 合成期间原来的分类并进了别的分类：拆开后是并进去的那个
        try await backend.mergeCategory(id: other.id, into: daily.id)
        try await backend.splitTransfer(recordID: w.spendID)
        detail = try await backend.recordDetail(id: w.spendID)
        XCTAssertEqual(detail.row.record.kind, .purchase)
        XCTAssertNil(detail.row.record.transferParty)
        XCTAssertEqual(detail.row.record.categoryID, daily.id)
        XCTAssertEqual(detail.row.record.note, "微信提现", "合成以后改的留着")
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

    /// 「我的 › 分类」长按拖动排顺序：存进账本，同一层没写到的排在后面
    func testReorderCategoriesKeepsNewOrder() async throws {
        let backend = try makeBackend()
        let tops = CategoryTree(try await backend.categories()).nodes(.expense, includeHidden: true).map(\.id)
        let other = try await category(backend, "其他")
        let fee = try await category(backend, "手续费")
        try await backend.reorderCategories([other.id, fee.id] + tops.filter { $0 != other.id && $0 != fee.id })
        var tree = CategoryTree(try await backend.categories())
        XCTAssertEqual(tree.nodes(.expense).prefix(3).map(\.category.name), ["其他", "手续费", "饮食"])

        let dinner = try await category(backend, "晚餐")
        let snack = try await category(backend, "饮料零食")
        try await backend.reorderCategories([snack.id, dinner.id])
        tree = CategoryTree(try await backend.categories())
        XCTAssertEqual(tree.nodes(.expense).first { $0.category.name == "饮食" }?.children.map(\.name), ["饮料零食", "晚餐", "早餐", "午餐"],
                       "没写到的按原来的顺序排在后面")
        XCTAssertEqual(tree.nodes(.expense).first?.category.name, "其他", "排小类不动大类")

        let food = try await category(backend, "饮食")
        do {
            try await backend.reorderCategories([food.id, dinner.id])
            XCTFail("大类和小类不能一起排")
        } catch BackendError.invalidCategory {}
        let salary = try await category(backend, "工资", type: .income)
        do {
            try await backend.reorderCategories([food.id, salary.id])
            XCTFail("支出和收入不能一起排")
        } catch BackendError.invalidCategory {}
        do {
            try await backend.reorderCategories([food.id, food.id])
            XCTFail("重复的")
        } catch BackendError.invalidCategory {}
        do {
            try await backend.reorderCategories(["missing"])
            XCTFail("没有这个分类")
        } catch BackendError.notFound {}
    }

    /// 把小类拖到别的大类上：挪进那个大类，排在最后；流水跟着这个小类走
    func testMoveSubcategoryToAnotherParent() async throws {
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let breakfast = try await category(backend, "早餐")
        let traffic = try await category(backend, "交通")
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 12_00, currency: .cny, categoryID: breakfast.id, time: now))
        try await backend.moveCategory(id: breakfast.id, toParent: traffic.id)
        var tree = CategoryTree(try await backend.categories())
        XCTAssertEqual(tree.nodes(.expense).first { $0.id == traffic.id }?.children.map(\.name), ["公交地铁", "打车", "加油停车", "火车飞机", "早餐"])
        XCTAssertEqual(tree.nodes(.expense).first { $0.category.name == "饮食" }?.children.map(\.name), ["午餐", "晚餐", "饮料零食"])
        let row = try await backend.records().first
        XCTAssertEqual(row?.category?.fullName, "交通 · 早餐")

        let transit = try await category(backend, "公交地铁")
        try await backend.reorderCategories([breakfast.id, transit.id])
        tree = CategoryTree(try await backend.categories())
        XCTAssertEqual(tree.nodes(.expense).first { $0.id == traffic.id }?.children.map(\.name), ["早餐", "公交地铁", "打车", "加油停车", "火车飞机"],
                       "挪进去以后在新的大类里也能排")

        let fee = try await category(backend, "手续费")
        do {
            try await backend.moveCategory(id: breakfast.id, toParent: fee.id)
            XCTFail("系统分类下面不能放小类")
        } catch BackendError.invalidCategory {}
        let food = try await category(backend, "饮食")
        do {
            try await backend.moveCategory(id: food.id, toParent: traffic.id)
            XCTFail("有小类的大类不能挪进别的大类")
        } catch BackendError.invalidCategory {}
        let salary = try await category(backend, "工资", type: .income)
        do {
            try await backend.moveCategory(id: breakfast.id, toParent: salary.id)
            XCTFail("不能挪到收入的大类下面")
        } catch BackendError.invalidCategory {}
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

    /// 统计页的占比：只在金额大于 0 的分类之间分，加起来正好 100
    func testCategoryPercentagesAddUpToHundred() async throws {
        func shares(_ amounts: [Int64]) -> [Int?] {
            MonthStats.CategoryTotal.percentages(amounts.map { .init(categoryID: nil, name: "", symbol: "", amountMinor: $0, count: 1) })
        }
        XCTAssertEqual(shares([500, 300, 200]), [50, 30, 20])
        XCTAssertEqual(shares([1, 1, 1]), [34, 33, 33], "取整后补给余数大的，一样大时补给前面的")
        XCTAssertEqual(shares([688_00, 100_00, -150_00]), [87, 13, nil], "只有退款的分类不算占比，也不从分母里扣")
        XCTAssertEqual(shares([99_999, 1]), [100, 0], "太小的是 0（显示 <1%）")
        XCTAssertEqual(shares([-5_00, 0]), [nil, nil])
        XCTAssertEqual(shares([]), [])

        // 退款记在这段时间里没有支出的分类：以前用支出减退款做分母，花得最多的分类占 128%
        let backend = try makeBackend()
        let cash = try await backend.addAccount(.pocket(name: "现金", type: .cash, currency: .cny, paletteID: "ocean"))
        let rent = try await category(backend, "房租")
        let clothes = try await category(backend, "衣着")
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 688_00, currency: .cny, categoryID: rent.id, time: now))
        try await backend.addRecord(ManualEntry(type: .expense, accountID: cash.id, amountMinor: 150_00, currency: .cny, categoryID: clothes.id, isRefund: true, time: now))
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.netExpenseMinor, 538_00)
        let percents = MonthStats.CategoryTotal.percentages(cny.expenseCategories)
        XCTAssertEqual(percents.compactMap { $0 }.reduce(0, +), 100)
        XCTAssertEqual(percents.compactMap { $0 }, [100])
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
        XCTAssertNil(rows.first?.record.chargeCurrency, "没填实际扣款不记扣款币种：以后账户加上日元，这笔就算在日元里")
        XCTAssertNil(rows.first?.record.settlementMinor)
        XCTAssertEqual(rows.first?.charge?.amountMinor, 48_00)
        XCTAssertEqual(rows.first?.charge?.isActual, false)

        // 填了实际扣款就用它
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: cny.id, amountMinor: 2_000, currency: .jpy, time: now.addingTimeInterval(60), settlementMinor: 95_10
        ))
        rows = try await backend.records(accountID: cny.id)
        XCTAssertEqual(rows.first?.record.chargeCurrency, .cny)
        XCTAssertEqual(rows.first?.record.settlementMinor, 95_10)
        XCTAssertEqual(rows.first?.charge?.isActual, true)

        // 转帐：转出的账户没有日元就按主币种扣款，到账写实际到了多少港币
        let ids = try await backend.addRecord(ManualEntry(
            type: .transfer, accountID: cny.id, toAccountID: hkd.id, amountMinor: 10_000, currency: .jpy,
            toAmountMinor: 520_00, toCurrency: .hkd, time: now.addingTimeInterval(120), settlementMinor: 480_00
        ))
        XCTAssertEqual(ids.count, 2)
        let out = try await backend.records(accountID: cny.id).first { $0.record.amountMinor == 10_000 }
        XCTAssertEqual(out?.record.chargeCurrency, .cny)
        XCTAssertEqual(out?.record.settlementMinor, 480_00)
        let into = try await backend.records(accountID: hkd.id).first
        XCTAssertEqual(into?.record.money, Money(minorUnits: 520_00, currency: .hkd))
        XCTAssertNil(into?.record.chargeCurrency)
        XCTAssertNil(into?.record.settlementMinor)
        XCTAssertEqual(into?.record.direction, .inflow)

        // 账户有这个币种：不存实际扣款
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: hkd.id, amountMinor: 50_00, currency: .hkd, time: now.addingTimeInterval(180), settlementMinor: 1
        ))
        let plain = try await backend.records(accountID: hkd.id).first { $0.record.amountMinor == 50_00 }
        XCTAssertNil(plain?.record.chargeCurrency)
        XCTAssertNil(plain?.record.settlementMinor)
    }

    /// 多币种账户：记一笔时可以选从哪个币种扣（例如人民币不够，银行扣了港币），编辑时可以改回来
    func testManualEntryCanChargeAnotherHeldCurrency() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: nil, bankName: "恒生银行", last4: "0105", cardType: .debit, currency: .hkd, paletteID: "ocean",
            openingBalanceMinor: 1_000_00, extraCurrencies: [.cny], extraOpeningBalances: [.cny: 10_00]
        ))
        let ids = try await backend.addRecord(ManualEntry(
            type: .expense, accountID: account.id, amountMinor: 80_00, currency: .cny, time: now.addingTimeInterval(60),
            chargeCurrency: .hkd, settlementMinor: 87_00
        ))
        var rows = try await backend.records(accountID: account.id)
        var row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.record.chargeCurrency, .hkd)
        XCTAssertEqual(row.record.settlementMinor, 87_00)
        XCTAssertEqual(row.charge, RecordCharge(currency: .hkd, amountMinor: 87_00, isActual: true, rateDay: nil))
        var summaries = try await backend.balanceSummaries()
        var balances = try XCTUnwrap(summaries[account.id])
        XCTAssertEqual(balances.item(.hkd)?.ledgerDerivedMinor, 1_000_00 - 87_00)
        XCTAssertEqual(balances.item(.cny)?.ledgerDerivedMinor, 10_00)

        // 改回人民币扣：不再记扣款币种，填的港币金额也不留
        try await backend.updateRecord(id: ids[0], RecordEdit(
            accountID: account.id, amountMinor: 80_00, currency: .cny, direction: .outflow, kind: .purchase,
            counterparty: nil, time: nil, note: "", chargeCurrency: .cny, settlementMinor: 87_00
        ))
        rows = try await backend.records(accountID: account.id)
        row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.record.chargeCurrency)
        XCTAssertNil(row.record.settlementMinor)
        XCTAssertNil(row.charge)
        summaries = try await backend.balanceSummaries()
        balances = try XCTUnwrap(summaries[account.id])
        XCTAssertEqual(balances.item(.cny)?.ledgerDerivedMinor, 10_00 - 80_00)

        // 选的不是账户的币种：按默认的，记在人民币
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: account.id, amountMinor: 1_00, currency: .cny, time: now.addingTimeInterval(120), chargeCurrency: .usd
        ))
        rows = try await backend.records(accountID: account.id)
        row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.record.chargeCurrency)
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
