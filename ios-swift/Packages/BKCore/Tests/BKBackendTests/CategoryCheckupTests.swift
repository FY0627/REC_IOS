import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 分类建议体检：按时间重放已经选好分类的流水，每笔只用它之前的记录算建议。商户、尾号、金额都是假的。
final class CategoryCheckupTests: XCTestCase {
    var sequence = 0

    func makeBackend() async throws -> LedgerBackend {
        let clock = CategoryLearningTests.Clock()
        let backend = LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { clock.tick() })
        _ = try await backend.addAccount(AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean"))
        return backend
    }

    @discardableResult
    func ingest(_ backend: LedgerBackend, _ text: String) async throws -> String {
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(Double(sequence) * 3600)))
        return try XCTUnwrap(result.items.first?.recordID)
    }

    func spend(_ backend: LedgerBackend, at merchant: String) async throws -> String {
        sequence += 1
        return try await ingest(backend, "您尾号8810的信用卡10月20日12:\(String(format: "%02d", sequence))消费人民币\(10 + sequence).00元，商户：\(merchant)。【中国银行】")
    }

    func category(_ backend: LedgerBackend, _ name: String) async throws -> LedgerCategory {
        let all = try await backend.categories()
        return try XCTUnwrap(all.first { $0.name == name && $0.type == .expense })
    }

    func testEmptyLedgerHasNothingToScore() async throws {
        let backend = try await makeBackend()
        let checkup = try await backend.categoryCheckup()
        XCTAssertEqual(checkup.all.count, 0)
        XCTAssertNil(checkup.all.averageTaps)
        XCTAssertEqual(checkup.autoFiling.map(\.filed), [0, 0])
    }

    func testReplayScoresEachPickWithOnlyEarlierRecords() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let snack = try await category(backend, "饮料零食")
        for _ in 0..<3 {
            let id = try await spend(backend, at: "财付通-测试外卖")
            try await backend.setCategory(recordID: id, categoryID: lunch.id)
        }
        // 第 4 笔连续选够 3 次，自动归类：不是用户选的，不打分，但算进常用分类
        let auto = try await spend(backend, at: "财付通-测试外卖")
        let autoRow = try await backend.recordDetail(id: auto).row
        XCTAssertEqual(autoRow.record.categoryAuto, true)
        // 中行的通知不写商户
        sequence += 1
        let plain = try await ingest(backend, "您的借记卡账户8810，于10月25日网上支付支取人民币15.64元,交易后余额62.36【中国银行】")
        try await backend.setCategory(recordID: plain, categoryID: snack.id)
        let before = try await backend.categorySuggestions(recordID: auto)

        let checkup = try await backend.categoryCheckup()
        XCTAssertEqual(checkup.all.count, 4)
        XCTAssertEqual(checkup.automatic, 4)

        // 第 1 笔没有可参考的；第 2、3 笔这个商户选过午餐，排第一
        XCTAssertEqual(checkup.withMerchant, CategoryCheckup.Score(count: 3, first: 2, panel: 2, notification: 3, taps: 12))
        // 没有商户：常用分类是午餐，饮料零食不在建议里；大类「饮食」在通知上，第二条通知的小类候选里没有它，点开面板选
        XCTAssertEqual(checkup.withoutMerchant, CategoryCheckup.Score(count: 1, first: 0, panel: 0, notification: 1, taps: 5))
        XCTAssertEqual(checkup.all.taps, 17)
        // 连续 3 次：打分的 3 笔之前最多连续 2 次，一笔也不会自动归；连续 2 次：第 3 笔会自动归，归对了
        XCTAssertEqual(checkup.autoFiling, [
            CategoryCheckup.AutoFiling(streak: 3, filed: 0, wrong: 0),
            CategoryCheckup.AutoFiling(streak: 2, filed: 1, wrong: 0),
        ])

        let after = try await backend.categorySuggestions(recordID: auto)
        XCTAssertEqual(after, before, "体检不改学到的规律")
    }

    func testChangedMindCountsAsWrongAutoFiling() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        for categoryID in [lunch.id, lunch.id, dinner.id] {
            let id = try await spend(backend, at: "测试餐厅")
            try await backend.setCategory(recordID: id, categoryID: categoryID)
        }
        let checkup = try await backend.categoryCheckup()
        XCTAssertEqual(checkup.autoFiling.last, CategoryCheckup.AutoFiling(streak: 2, filed: 1, wrong: 1), "连续 2 次就自动归的话，第 3 笔会归错")
        XCTAssertEqual(checkup.withMerchant.first, 1)
    }
}
