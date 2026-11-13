import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 学分类按时段分开记、三餐跟着时间、小词库只排推荐（ADR 0026）。商户、尾号、金额都是编的
final class MealTimeLearningTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }

    func makeBackend() async throws -> LedgerBackend {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        let backend = LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { start })
        _ = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0002", cardType: .debit, currency: .cny, paletteID: "ocean"))
        return backend
    }

    /// 招行短信：11 月 `day` 日 `hour`:`minute` 在「财付通-商户」付了一笔
    @discardableResult
    func pay(_ backend: LedgerBackend, _ merchant: String, day: Int, _ hour: Int, _ minute: Int, yuan: Int = 30) async throws -> String {
        let time = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        let text = String(format: "您账户0002于11月%02d日%02d:%02d在【财付通-%@】发生快捷支付扣款，人民币%d.00", day, hour, minute, merchant, yuan)
        let result = try await backend.ingest(IngestRequest(text: text, source: .auto, receivedAt: time.addingTimeInterval(20)))
        return try XCTUnwrap(result.items.first?.recordID, result.summary)
    }

    func category(_ backend: LedgerBackend, _ name: String) async throws -> LedgerCategory {
        let all = try await backend.categories()
        return try XCTUnwrap(all.first { $0.name == name && $0.type == .expense }, name)
    }

    func row(_ backend: LedgerBackend, _ id: String) async throws -> LedgerRecord {
        try await backend.recordDetail(id: id).row.record
    }

    /// 美团中午连着选 3 次午餐
    func learnLunch(_ backend: LedgerBackend) async throws -> LedgerCategory {
        let lunch = try await category(backend, "午餐")
        for (day, minute) in [(2, 10), (3, 20), (4, 15)] {
            let id = try await pay(backend, "美团", day: day, 12, minute, yuan: 30 + day)
            try await backend.setCategory(recordID: id, categoryID: lunch.id)
        }
        return lunch
    }

    // MARK: 饭点

    func testDefaultMealSlots() {
        let times = MealTimes.defaults
        let cases: [(Int, Int, MealSlot)] = [
            (2, 0, .other), (4, 59, .other), (5, 0, .breakfast), (7, 30, .breakfast), (9, 59, .breakfast),
            (10, 0, .lunch), (13, 59, .lunch), (14, 30, .other), (15, 59, .other), (16, 0, .dinner), (23, 30, .dinner),
        ]
        for (hour, minute, slot) in cases {
            XCTAssertEqual(times.slot(minute: hour * 60 + minute), slot, "\(hour):\(minute)")
        }
    }

    func testOwnMealTimesReplaceTheDefaults() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        for day in 2...6 {
            let id = try await pay(backend, "小巷面馆", day: day, 12, 30, yuan: 20 + day)
            try await backend.setCategory(recordID: id, categoryID: lunch.id)
        }
        let calendar = calendar
        let times = try await backend.database.read { db in
            try MealTimes.load(db, tree: CategoryTree(try CategoryDAO.all(db)), calendar: calendar)
        }
        XCTAssertEqual(times.slot(minute: 11 * 60), .lunch, "12:30 前后一个半小时")
        XCTAssertEqual(times.slot(minute: 13 * 60 + 59), .lunch)
        XCTAssertEqual(times.slot(minute: 14 * 60), .other)
        XCTAssertEqual(times.slot(minute: 10 * 60 + 30), .other, "默认的 10 点起算午餐换成了自己的")
        XCTAssertEqual(times.slot(minute: 8 * 60), .breakfast, "早餐自己的流水不够，还是默认的")
    }

    // MARK: 按时段自动归类

    func testOffHourPickDoesNotBreakMealTimeAutoFiling() async throws {
        let backend = try await makeBackend()
        let lunch = try await learnLunch(backend)
        // 下午 3 点在美团买了点东西：不是饭点，不自动归；选了日用品
        let afternoon = try await pay(backend, "美团", day: 5, 15, 0, yuan: 59)
        let afternoonRecord = try await row(backend, afternoon)
        XCTAssertNil(afternoonRecord.categoryID)
        let daily = try await category(backend, "日用品")
        try await backend.setCategory(recordID: afternoon, categoryID: daily.id)
        // 第二天中午：照样自动归到午餐
        let noon = try await pay(backend, "美团", day: 6, 12, 20, yuan: 33)
        let noonRecord = try await row(backend, noon)
        XCTAssertEqual(noonRecord.categoryID, lunch.id)
        XCTAssertTrue(noonRecord.categoryAuto)
    }

    func testMealFollowsTheTime() async throws {
        let backend = try await makeBackend()
        _ = try await learnLunch(backend)
        let dinner = try await category(backend, "晚餐")
        let evening = try await pay(backend, "美团", day: 5, 19, 30, yuan: 45)
        let record = try await row(backend, evening)
        XCTAssertEqual(record.categoryID, dinner.id, "学到的是一顿饭，晚上就是晚餐")
        XCTAssertTrue(record.categoryAuto)
    }

    func testOffHourMealIsOnlySuggested() async throws {
        let backend = try await makeBackend()
        let lunch = try await learnLunch(backend)
        let afternoon = try await pay(backend, "美团", day: 5, 15, 0, yuan: 28)
        let record = try await row(backend, afternoon)
        XCTAssertNil(record.categoryID)
        let suggestions = try await backend.categorySuggestions(recordID: afternoon)
        XCTAssertEqual(suggestions.quick.first?.id, lunch.id)
    }

    // MARK: 小词库

    func testLexiconRanksFirstWithoutAutoFiling() async throws {
        let backend = try await makeBackend()
        let cases: [(String, Int, Int, String)] = [
            ("城市地铁", 8, 40, "公交地铁"), ("小巷面馆", 12, 10, "午餐"), ("小巷面馆", 19, 10, "晚餐"),
            ("小巷面馆", 15, 0, "饮食"), ("滴滴出行", 22, 5, "打车"), ("城市燃气", 19, 40, "水电燃气"),
        ]
        for (index, (merchant, hour, minute, expected)) in cases.enumerated() {
            let id = try await pay(backend, merchant, day: 2 + index, hour, minute, yuan: 11 + index)
            let record = try await row(backend, id)
            XCTAssertNil(record.categoryID, "\(merchant) 只排推荐，不自动归")
            let suggestions = try await backend.categorySuggestions(recordID: id)
            XCTAssertEqual(suggestions.quick.first?.name, expected, "\(merchant) \(hour):\(minute)")
            XCTAssertNil(suggestions.preferredID, "猜的不当成选过的")
        }
    }

    func testOwnPickBeatsTheLexicon() async throws {
        let backend = try await makeBackend()
        let daily = try await category(backend, "日用品")
        let first = try await pay(backend, "城市地铁", day: 2, 8, 40, yuan: 50)
        try await backend.setCategory(recordID: first, categoryID: daily.id)
        let second = try await pay(backend, "城市地铁", day: 3, 8, 41, yuan: 51)
        let suggestions = try await backend.categorySuggestions(recordID: second)
        XCTAssertEqual(suggestions.quick.first?.id, daily.id)
    }

    // MARK: 存的样子

    func testSlotRowsStayOutOfTheExport() async throws {
        let backend = try await makeBackend()
        _ = try await learnLunch(backend)
        let (entries, rows) = try await backend.database.read { db in
            (try MerchantCategoryDAO.all(db), try db.scalarInt("SELECT COUNT(*) FROM merchant_categories"))
        }
        XCTAssertEqual(entries.map(\.merchant), ["expense|美团"])
        XCTAssertEqual(rows, 2, "不分时段的一行，午餐时段的一行")
    }

    /// 以前学过的账本（没有时段）：打开时按流水补上时段，不分时段的不重复算
    func testSeedFillsTimeSlotsForOldLearning() async throws {
        let backend = try await makeBackend()
        _ = try await learnLunch(backend)
        let before = try await backend.database.write { db -> [MerchantCategoryDAO.Entry] in
            try db.run("DELETE FROM merchant_categories WHERE instr(merchant, char(31)) > 0", [])
            try SettingsDAO.set(db, LedgerBackend.learningSeededKey, "1")
            return try MerchantCategoryDAO.all(db)
        }
        try await backend.seedCategoryLearning()
        let (after, slots) = try await backend.database.read { db in
            (try MerchantCategoryDAO.all(db), try db.scalarInt("SELECT COUNT(*) FROM merchant_categories WHERE instr(merchant, char(31)) > 0"))
        }
        XCTAssertEqual(after, before)
        XCTAssertEqual(slots, 1)
        // 补上以后中午照样自动归
        let lunch = try await category(backend, "午餐")
        let noon = try await pay(backend, "美团", day: 6, 12, 25, yuan: 36)
        let record = try await row(backend, noon)
        XCTAssertEqual(record.categoryID, lunch.id)
    }
}
