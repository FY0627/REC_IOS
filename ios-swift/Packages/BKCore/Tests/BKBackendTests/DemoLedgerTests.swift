import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 演示账本（ADR 0025）：编的通知都要按预期入账，账户、待处理、分类学习要像用了三个月的样子；
/// 演示账本里的模拟消费记在演示的卡上，常去的店自动归类，没去过的店给推荐
final class DemoLedgerTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    /// 2026-11-13 15:00 +08:00（星期五）
    let now = Date(timeIntervalSince1970: 1_794_553_200)

    func makeBackend(now: Date? = nil) throws -> LedgerBackend {
        let now = now ?? self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    func seeded(_ language: DemoLanguage = .zhHans, now: Date? = nil) async throws -> (LedgerBackend, DemoSummary) {
        let backend = try makeBackend(now: now)
        let summary = try await backend.seedDemo(language: language)
        return (backend, summary)
    }

    func testEveryLanguageBooksEveryNoticeAsPlanned() async throws {
        for language in DemoLanguage.allCases {
            let (backend, summary) = try await seeded(language)
            XCTAssertEqual(summary.accounts, 6, language.rawValue)
            XCTAssertGreaterThan(summary.records, 300, language.rawValue)

            // 只有故意留的三条待处理，别的通知、截图都入账了
            let pending = try await backend.openPendingItems()
            XCTAssertEqual(Set(pending.map(\.reason)), [.noMatchingAccount, .ambiguousAccount, .possibleDuplicate], language.rawValue)
            let log = try await backend.ingestLog(limit: 1000)
            let missed = log.filter { $0.outcome != .recorded && $0.outcome != .pending }
            XCTAssertTrue(missed.isEmpty, "\(language.rawValue): \(missed.map { $0.rawText ?? "" })")

            // 待分类只有转给朋友、还没确认对方的那一笔
            let waiting = try await backend.uncategorized()
            XCTAssertEqual(waiting.count, 1, language.rawValue)
            XCTAssertTrue(waiting.allSatisfy(\.record.needsTransferConfirmation), language.rawValue)
        }
    }

    func testAccountsLookLived() async throws {
        let (backend, _) = try await seeded()
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.map(\.cardType), [.debit, .debit, .credit, .wallet, .wallet, .cash])
        let hangSeng = try XCTUnwrap(accounts.first { $0.bankID == "hangseng" })
        XCTAssertEqual(hangSeng.currencies, [.hkd, .cny, .usd], "多币种卡")

        let balances = try await backend.balanceSummaries()
        for account in accounts where account.cardType != .credit {
            for item in balances[account.id]?.items ?? [] {
                XCTAssertGreaterThan(item.ledgerDerivedMinor ?? -1, 0, "\(account.name) \(item.currency.rawValue)")
            }
        }
        // 每个账户都有流水，美元卡上有美元的订阅
        for account in accounts {
            let count = try await backend.recordCount(accountID: account.id)
            XCTAssertGreaterThan(count, 5, account.name)
        }
        let usd = try await backend.records(filter: RecordFilter(accountID: hangSeng.id, currency: .usd), limit: 50)
        XCTAssertTrue(usd.contains { $0.record.currency == .usd && $0.record.direction == .outflow })

        // 收入、支出、转帐都有，还有换汇
        let rows = try await backend.records(filter: RecordFilter(), limit: 2000)
        XCTAssertEqual(Set(rows.map(\.record.entryType)), [.expense, .income, .transfer])
        XCTAssertTrue(rows.contains { $0.record.accountID == hangSeng.id && $0.record.entryType == .transfer && $0.record.currency == .hkd })
        XCTAssertFalse(rows.contains { $0.record.effectiveAt > now }, "没有将来的流水")
    }

    func testForeignHoldClosesIntoTheCharge() async throws {
        let (backend, _) = try await seeded()
        let rows = try await backend.records(filter: RecordFilter(), limit: 2000)
        XCTAssertFalse(rows.contains { $0.record.status == .hold }, "冻结已经了结")
        let charge = try XCTUnwrap(rows.first { $0.record.counterparty?.hasPrefix("SAKURA STATIONERY") == true })
        XCTAssertEqual(charge.record.currency, .cny)
        let detail = try await backend.recordDetail(id: charge.id)
        XCTAssertEqual(detail.closedHolds.count, 1)
        XCTAssertEqual(detail.closedHolds.first?.record.currency, .jpy)
    }

    func testMerchantsAndCategoriesFollowTheLanguage() async throws {
        let expected: [DemoLanguage: (String, String)] = [
            .zhHans: ("老街牛肉面", "买菜"), .zhHant: ("老街牛肉麵", "買菜"), .english: ("Old Street Noodles", "Groceries"),
        ]
        for (language, (noodles, groceries)) in expected {
            let (backend, _) = try await seeded(language)
            let rows = try await backend.records(filter: RecordFilter(), limit: 2000)
            XCTAssertTrue(rows.contains { $0.record.counterparty == noodles }, language.rawValue)
            let categories = try await backend.categories()
            XCTAssertEqual(categories.first { $0.id == DemoCategory.groceries }?.name, groceries, language.rawValue)
            let used = Set(rows.compactMap(\.record.categoryID))
            XCTAssertTrue(used.isSuperset(of: [DemoCategory.groceries, DemoCategory.subscriptions, DemoCategory.cashback]), language.rawValue)
            let language = try await backend.demoLanguage()
            XCTAssertNotNil(language)
        }
    }

    func testLearnedCategoriesShowOff() async throws {
        let (backend, _) = try await seeded(.english)
        let rows = try await backend.records(filter: RecordFilter(), limit: 2000)
        XCTAssertGreaterThan(rows.filter(\.record.categoryAuto).count, 80, "常去的店后来都自动归类")
        // App 打开账本时不再回放学习、不重读待处理
        let seeded = try await backend.database.read { try SettingsDAO.get($0, LedgerBackend.learningSeededKey) }
        XCTAssertEqual(seeded, "1")
        let reread = try await backend.rereadPending()
        XCTAssertEqual(reread, 0)

        // 常去的店：模拟一笔，自动归类
        for (index, spend) in [SimulatedSpend.breakfast, .lunch, .coffee, .taxi].enumerated() {
            let result = try await backend.simulateSpend(spend, amountMinor: Int64(1_800 + index * 731))
            let item = try XCTUnwrap(result.items.first)
            XCTAssertEqual(item.result, .recorded, spend.title)
            let row = try await backend.recordDetail(id: try XCTUnwrap(item.recordID)).row
            XCTAssertEqual(row.record.counterparty, spend.merchant(in: .english), spend.title)
            XCTAssertEqual(row.last4, DemoPlan.bocTail, spend.title)
            XCTAssertTrue(row.record.categoryAuto, spend.title)
        }

        // 便利店选过两个分类：不自动归，两个都排在推荐最前面
        let store = try await backend.simulateSpend(.store, amountMinor: 1_200)
        let storeID = try XCTUnwrap(store.items.first?.recordID)
        let storeRow = try await backend.recordDetail(id: storeID).row
        XCTAssertNil(storeRow.record.categoryID)
        let storeSuggestions = try await backend.categorySuggestions(recordID: storeID)
        XCTAssertEqual(Set(storeSuggestions.quick.prefix(2).map(\.id)), [DemoCategory.snack, DemoCategory.daily])

        // 没去过的店：按常用的分类推荐
        let dinner = try await backend.simulateSpend(.dinner, amountMinor: 6_800)
        let dinnerID = try XCTUnwrap(dinner.items.first?.recordID)
        let dinnerSuggestions = try await backend.categorySuggestions(recordID: dinnerID)
        XCTAssertNil(dinnerSuggestions.autoCategory)
        XCTAssertTrue(dinnerSuggestions.quick.prefix(4).contains { $0.id == DemoCategory.lunch })

        // 一键清除只删模拟的那几笔，演示的卡还在
        let count = try await backend.simulatedRecordCount()
        XCTAssertEqual(count, 6)
        let removed = try await backend.clearSimulation()
        XCTAssertEqual(removed, 6)
        let after = try await backend.records(filter: RecordFilter(), limit: 2000)
        XCTAssertEqual(after.count, rows.count)
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.count, 6)
    }

    func testEarlyMorningHasNoFutureRecords() async throws {
        // 00:20：今天还没有流水，待处理挪到昨天
        let early = calendar.startOfDay(for: now).addingTimeInterval(20 * 60)
        let (backend, summary) = try await seeded(.zhHant, now: early)
        XCTAssertEqual(summary.pending, 3)
        let rows = try await backend.records(filter: RecordFilter(), limit: 2000)
        XCTAssertFalse(rows.contains { $0.record.effectiveAt > early })
    }

    func testRealLedgerSimulationIsUnchanged() async throws {
        let backend = try makeBackend()
        let language = try await backend.demoLanguage()
        XCTAssertNil(language)
        let result = try await backend.simulateSpend(.coffee, amountMinor: 1_500)
        let row = try await backend.recordDetail(id: try XCTUnwrap(result.items.first?.recordID)).row
        XCTAssertEqual(row.record.counterparty, "模拟·瑞幸咖啡")
        XCTAssertEqual(row.last4, "9999")
    }
}
