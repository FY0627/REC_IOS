import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 模拟消费：编出来的短信和真的一样入账、学分类；一键清除后账本回到模拟之前。
final class SimulationTests: XCTestCase {
    func makeBackend() throws -> LedgerBackend {
        let clock = CategoryLearningTests.Clock()
        return LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { clock.tick() })
    }

    func testEverySpendIsRecordedOnTheSimulatedCard() async throws {
        let backend = try makeBackend()
        for (index, spend) in SimulatedSpend.allCases.enumerated() {
            let result = try await backend.simulateSpend(spend, amountMinor: Int64(1_000 + index * 101))
            let item = try XCTUnwrap(result.items.first, spend.title)
            XCTAssertEqual(item.result, .recorded, spend.title)
            let row = try await backend.recordDetail(id: try XCTUnwrap(item.recordID)).row
            XCTAssertEqual(row.record.kind, .purchase, spend.title)
            XCTAssertEqual(row.record.counterparty, spend.merchant.map { "模拟·" + $0 }, spend.title)
            XCTAssertEqual(row.record.amountMinor, Int64(1_000 + index * 101), spend.title)
            XCTAssertEqual(row.bankName, "工商银行")
            XCTAssertEqual(row.last4, "9999")
        }
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.count, 1, "只建一张模拟卡")
        let count = try await backend.simulatedRecordCount()
        XCTAssertEqual(count, SimulatedSpend.allCases.count)
    }

    func testThreePicksAutoFileTheFourthCoffee() async throws {
        let backend = try makeBackend()
        let all = try await backend.categories()
        let snack = try XCTUnwrap(all.first { $0.name == "饮料零食" })
        for index in 0..<3 {
            let result = try await backend.simulateSpend(.coffee, amountMinor: Int64(1_500 + index))
            try await backend.setCategory(recordID: try XCTUnwrap(result.items.first?.recordID), categoryID: snack.id)
        }
        let fourth = try await backend.simulateSpend(.coffee, amountMinor: 1_600)
        let row = try await backend.recordDetail(id: try XCTUnwrap(fourth.items.first?.recordID)).row
        XCTAssertEqual(row.record.categoryID, snack.id)
        XCTAssertTrue(row.record.categoryAuto)
    }

    func testClearLeavesRealDataAlone() async throws {
        let backend = try makeBackend()
        let all = try await backend.categories()
        let snack = try XCTUnwrap(all.first { $0.name == "饮料零食" })
        // 真的卡、真的瑞幸
        _ = try await backend.addAccount(AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean"))
        let real = try await backend.ingest(IngestRequest(
            text: "您尾号8810的信用卡10月20日12:01消费人民币18.00元，商户：瑞幸咖啡。【中国银行】", source: .sms, receivedAt: ParserSampleTests.reference
        ))
        let realID = try XCTUnwrap(real.items.first?.recordID)
        try await backend.setCategory(recordID: realID, categoryID: snack.id)
        for index in 0..<3 {
            let result = try await backend.simulateSpend(.coffee, amountMinor: Int64(1_500 + index))
            try await backend.setCategory(recordID: try XCTUnwrap(result.items.first?.recordID), categoryID: snack.id)
        }

        let removed = try await backend.clearSimulation()
        XCTAssertEqual(removed, 3)
        let accounts = try await backend.accounts(includeArchived: true, includeDeleted: true)
        XCTAssertEqual(accounts.map(\.last4), ["8810"], "模拟卡整张删掉，不留「已删除」")
        let records = try await backend.records(limit: 100)
        XCTAssertEqual(records.map(\.id), [realID])
        let log = try await backend.ingestLog(limit: 100)
        XCTAssertFalse(log.contains { $0.sender == "模拟消费" }, "模拟的通知不留在接收日志里")
        let simulated = try await backend.simulatedRecordCount()
        XCTAssertEqual(simulated, 0)

        // 模拟时学到的「模拟·瑞幸咖啡」清掉了，真的瑞幸学到的还在
        let next = try await backend.ingest(IngestRequest(
            text: "您尾号8810的信用卡10月21日12:01消费人民币19.00元，商户：瑞幸咖啡。【中国银行】", source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(86_400)
        ))
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.items.first?.recordID))
        XCTAssertEqual(suggestions.preferredID, snack.id)
        let again = try await backend.simulateSpend(.coffee, amountMinor: 1_700)
        let fresh = try await backend.categorySuggestions(recordID: try XCTUnwrap(again.items.first?.recordID))
        XCTAssertNil(fresh.preferredID, "重新模拟从头学")
    }
}
