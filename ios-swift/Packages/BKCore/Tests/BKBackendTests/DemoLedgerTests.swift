import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 演示账本（ADR 0025）：只有账户、初始余额和汇率，像刚加完卡的用户；之后来的通知照常入账、算进余额
final class DemoLedgerTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    /// 2026-11-13 15:00 +08:00
    let now = Date(timeIntervalSince1970: 1_794_553_200)

    func seeded() async throws -> LedgerBackend {
        let now = self.now
        let backend = LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
        try await backend.seedDemo()
        return backend
    }

    func testOnlyAccountsBalancesAndRates() async throws {
        let backend = try await seeded()
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.map(\.cardType), [.debit, .debit, .credit, .wallet, .wallet, .cash])
        XCTAssertEqual(accounts.first { $0.bankID == "hangseng" }?.currencies, [.hkd, .cny, .usd], "多币种卡")
        XCTAssertEqual(Set(accounts.map(\.last4)).count, 4, "三张卡尾号不同，现金和钱包没有尾号")

        let balances = try await backend.balanceSummaries()
        for account in accounts {
            for item in balances[account.id]?.items ?? [] {
                XCTAssertEqual(item.ledgerDerivedMinor, item.openingBalanceMinor, "\(account.name) \(item.currency.rawValue)")
                XCTAssertNotNil(item.openingBalanceMinor)
            }
        }

        // 没有流水、待处理、学到的分类，分类是默认的那套
        let records = try await backend.recordCount()
        let pending = try await backend.pendingCount()
        XCTAssertEqual(records, 0)
        XCTAssertEqual(pending, 0)
        let learned = try await backend.database.read { try $0.scalarInt("SELECT COUNT(*) FROM merchant_categories") }
        XCTAssertEqual(learned, 0)
        let fresh = try LedgerBackend.inMemory(calendar: calendar)
        let defaults = try await fresh.categories()
        let categories = try await backend.categories()
        XCTAssertEqual(categories.map(\.id), defaults.map(\.id))

        // 今天的汇率：净资产能换算
        let latest = try await backend.latestExchangeRates()
        let rates = try XCTUnwrap(latest)
        XCTAssertTrue(calendar.isDate(rates.updatedAt, inSameDayAs: now))
        XCTAssertNotNil(rates.convert(10_000, from: .hkd, to: .cny))
    }

    func testLaterNoticesCountIntoBalances() async throws {
        let backend = try await seeded()
        let accounts = try await backend.accounts()
        let cmb = try XCTUnwrap(accounts.first { $0.bankID == "cmb" })
        // 十天前的一条招行推送：账户是 30 天前加的，算进余额
        let result = try await backend.ingest(IngestRequest(
            text: "动账提醒\n您尾号2046的储蓄账户11月3日12时5分支出人民币36.50元。点击查看>>", source: .auto, receivedAt: now
        ))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let balance = try await backend.balanceSummaries()[cmb.id]?.primary?.ledgerDerivedMinor
        XCTAssertEqual(balance, 1_248_000 - 3_650)
    }
}
