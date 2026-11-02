import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 学习归类（ADR 0017）：候选排序、连续选够才自动归类、改掉后重新学、分类删除合并时学到的怎么处理。
/// 商户、尾号、金额都是假的。
final class CategoryLearningTests: XCTestCase {
    /// 每次取时间往后走一分钟：「最近选的」排在前面
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ParserSampleTests.reference

        func tick() -> Date {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(60)
            return current
        }
    }

    /// 同一条通知内容不重复：金额和分钟每笔都不同
    var sequence = 0

    func makeBackend() async throws -> LedgerBackend {
        let clock = Clock()
        let backend = LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { clock.tick() })
        _ = try await backend.addAccount(AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean"))
        return backend
    }

    /// 消费一笔，返回入账的结果
    @discardableResult
    func spend(_ backend: LedgerBackend, at merchant: String) async throws -> IngestItem {
        sequence += 1
        let text = "您尾号8810的信用卡10月20日12:\(String(format: "%02d", sequence))消费人民币\(10 + sequence).00元，商户：\(merchant)。【中国银行】"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(Double(sequence) * 3600)))
        return try XCTUnwrap(result.items.first)
    }

    func spendAndPick(_ backend: LedgerBackend, at merchant: String, _ categoryID: String) async throws {
        let item = try await spend(backend, at: merchant)
        try await backend.setCategory(recordID: try XCTUnwrap(item.recordID), categoryID: categoryID)
    }

    func category(_ backend: LedgerBackend, _ name: String, type: CategoryType = .expense) async throws -> LedgerCategory {
        let all = try await backend.categories()
        return try XCTUnwrap(all.first { $0.name == name && $0.type == type })
    }

    func record(_ backend: LedgerBackend, _ id: String?) async throws -> RecordRow {
        try await backend.recordDetail(id: try XCTUnwrap(id)).row
    }

    // MARK: 候选

    func testFirstPickPutsCategoryFirstWithoutAutomating() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        try await spendAndPick(backend, at: "财付通-测试外卖", lunch.id)

        let next = try await spend(backend, at: "财付通-测试外卖")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category, "只选过一次：还是待分类")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertEqual(suggestions.categories.first?.id, lunch.id)
        XCTAssertEqual(suggestions.preferredID, lunch.id, "这个商户选过的：打开面板时预先选好")
        XCTAssertEqual(suggestions.categories.count, CategoryLearner.suggestionLimit)
        XCTAssertNil(suggestions.autoCategory)
    }

    func testLatestPickComesFirstThenFrequentCategories() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        let daily = try await category(backend, "日用品")
        let book = try await category(backend, "书")
        for _ in 0..<2 { try await spendAndPick(backend, at: "测试书店", book.id) }
        try await spendAndPick(backend, at: "测试超市", lunch.id)
        try await spendAndPick(backend, at: "测试超市", daily.id)
        try await spendAndPick(backend, at: "测试超市", dinner.id)

        let next = try await spend(backend, at: "测试超市")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertEqual(suggestions.categories.map(\.id), [dinner.id, daily.id, lunch.id, book.id], "商户选过的最近的在前，再用常用分类补齐")
    }

    func testRecordWithoutMerchantIsRankedByFrequentCategoriesOnly() async throws {
        let backend = try await makeBackend()
        let snack = try await category(backend, "饮料零食")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试奶茶", snack.id) }

        // 中行的通知不写商户
        for minute in 1...5 {
            let text = "您的借记卡账户8810，于10月2\(minute)日网上支付支取人民币1\(minute).64元,交易后余额62.36【中国银行】"
            let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(Double(minute) * 86_400)))
            let id = try XCTUnwrap(result.items.first?.recordID)
            let row = try await record(backend, id)
            XCTAssertNil(row.category, "看不出商户，绝不自动归类")
            let suggestions = try await backend.categorySuggestions(recordID: id)
            XCTAssertEqual(suggestions.categories.first?.id, snack.id, "常用分类排在前面")
            XCTAssertNil(suggestions.preferredID, "不是这个商户选过的，不预先选")
            try await backend.setCategory(recordID: id, categoryID: snack.id)
        }
    }

    func testCollectionCodesAreNeverLearned() async throws {
        let backend = try await makeBackend()
        let food = try await category(backend, "饮食")
        for merchant in ["ALP*QRCode0055", "Scan QR code"] {
            for _ in 0..<4 { try await spendAndPick(backend, at: merchant, food.id) }
            let next = try await spend(backend, at: merchant)
            let row = try await record(backend, next.recordID)
            XCTAssertNil(row.category, "\(merchant) 不是商户，选多少次都不自动归类")
        }
    }

    func testHiddenAndSystemCategoriesAreNotSuggested() async throws {
        let backend = try await makeBackend()
        let snack = try await category(backend, "饮料零食")
        let food = try await category(backend, "饮食")
        let fee = try await category(backend, "手续费")
        try await spendAndPick(backend, at: "测试奶茶", snack.id)
        try await spendAndPick(backend, at: "测试奶茶", fee.id)
        try await backend.setCategoryHidden(id: food.id, hidden: true)

        let next = try await spend(backend, at: "测试奶茶")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertFalse(suggestions.categories.contains { $0.id == snack.id }, "大类隐藏了，小类也不出现")
        XCTAssertFalse(suggestions.categories.contains { $0.id == fee.id }, "手续费不当候选")
        XCTAssertFalse(suggestions.categories.contains { $0.id == food.id })
        XCTAssertEqual(suggestions.categories.count, CategoryLearner.suggestionLimit)
    }

    // MARK: 自动归类

    func testThreePicksInARowAutomateTheNextOne() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        for _ in 0..<2 { try await spendAndPick(backend, at: "财付通-测试外卖", lunch.id) }
        try await spendAndPick(backend, at: "支付宝-测试外卖", lunch.id)
        let waitingBefore = try await backend.uncategorizedCount()

        let next = try await spend(backend, at: "财付通-测试外卖（人民路店）")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.category?.id, lunch.id, "渠道和分店不同，是同一个商户")
        XCTAssertTrue(row.record.categoryAuto, "看得出是自动归类的")
        let waitingAfter = try await backend.uncategorizedCount()
        XCTAssertEqual(waitingAfter, waitingBefore, "不进待分类")

        let suggestions = try await backend.categorySuggestions(recordID: row.id)
        XCTAssertEqual(suggestions.autoCategory?.id, lunch.id)
        XCTAssertFalse(suggestions.categories.contains { $0.id == lunch.id }, "按钮是改成别的分类")
        XCTAssertNil(suggestions.preferredID)
    }

    func testPicksThatChangeInBetweenDoNotAutomate() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let daily = try await category(backend, "日用品")
        for id in [lunch.id, lunch.id, daily.id, lunch.id] { try await spendAndPick(backend, at: "测试超市", id) }
        let next = try await spend(backend, at: "测试超市")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category, "A、A、B、A 不算连续")
    }

    func testCorrectingAnAutoCategoryStartsOver() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试外卖", lunch.id) }
        let wrong = try await spend(backend, at: "测试外卖")
        let wrongID = try XCTUnwrap(wrong.recordID)
        try await backend.setCategory(recordID: wrongID, categoryID: dinner.id)
        let corrected = try await record(backend, wrongID)
        XCTAssertFalse(corrected.record.categoryAuto, "改过就不再是自动归类")

        // 改成晚餐算第一次：再选两次才够三次
        for count in 2...3 {
            let next = try await spend(backend, at: "测试外卖")
            let row = try await record(backend, next.recordID)
            XCTAssertNil(row.category, "重新学：第 \(count) 次还要选")
            let suggestions = try await backend.categorySuggestions(recordID: row.id)
            XCTAssertEqual(suggestions.categories.first?.id, dinner.id, "最近选的排在最前面")
            try await backend.setCategory(recordID: row.id, categoryID: dinner.id)
        }
        let next = try await spend(backend, at: "测试外卖")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.category?.id, dinner.id)
        XCTAssertTrue(row.record.categoryAuto)
    }

    func testChangingCategoryInTheEditorAlsoStartsOver() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试外卖", lunch.id) }
        let wrong = try await spend(backend, at: "测试外卖")
        let row = try await record(backend, wrong.recordID)
        XCTAssertTrue(row.record.categoryAuto)

        func edit(_ r: LedgerRecord, category: String) -> RecordEdit {
            RecordEdit(
                accountID: r.accountID, amountMinor: r.amountMinor, currency: r.currency, direction: r.direction, kind: r.kind,
                counterparty: r.counterparty, time: nil, note: "", categoryID: category, keepsCategory: false
            )
        }
        try await backend.updateRecord(id: row.id, edit(row.record, category: lunch.id))
        let same = try await record(backend, row.id)
        XCTAssertTrue(same.record.categoryAuto, "分类没变：还是自动归类的")

        try await backend.updateRecord(id: row.id, edit(row.record, category: dinner.id))
        let changed = try await record(backend, row.id)
        XCTAssertFalse(changed.record.categoryAuto)
        let next = try await spend(backend, at: "测试外卖")
        let nextRow = try await record(backend, next.recordID)
        XCTAssertNil(nextRow.category, "改掉一次，重新学")
    }

    func testSavingTheSameCategoryAgainDoesNotCount() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let item = try await spend(backend, at: "测试外卖")
        let id = try XCTUnwrap(item.recordID)
        for _ in 0..<4 { try await backend.setCategory(recordID: id, categoryID: lunch.id) }
        let next = try await spend(backend, at: "测试外卖")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category, "同一笔反复保存只算一次")
    }

    func testHiddenCategoryIsNotUsedAutomatically() async throws {
        let backend = try await makeBackend()
        let daily = try await category(backend, "日用品")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试超市", daily.id) }
        try await backend.setCategoryHidden(id: daily.id, hidden: true)
        let next = try await spend(backend, at: "测试超市")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category)
    }

    // MARK: 先选大类，再选小类

    func testNotificationOffersTopLevelCategories() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        let food = try await category(backend, "饮食")
        try await spendAndPick(backend, at: "测试小馆", dinner.id)
        try await spendAndPick(backend, at: "测试小馆", lunch.id)
        let next = try await spend(backend, at: "测试小馆")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertEqual(suggestions.categories.first, lunch, "面板的建议可以是小类")
        XCTAssertEqual(suggestions.topCategories.first, food)
        XCTAssertEqual(suggestions.topCategories.count, CategoryLearner.notificationLimit)
        XCTAssertTrue(suggestions.topCategories.allSatisfy(\.isTopLevel))
        XCTAssertEqual(Set(suggestions.topCategories.map(\.id)).count, suggestions.topCategories.count, "两个小类同属一个大类，大类只出现一次")
    }

    func testAutoCategorizedRecordOffersOtherTopLevelCategories() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let food = try await category(backend, "饮食")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试小馆", lunch.id) }
        let next = try await spend(backend, at: "测试小馆")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertEqual(suggestions.autoCategory, lunch)
        XCTAssertFalse(suggestions.topCategories.isEmpty)
        XCTAssertFalse(suggestions.topCategories.contains(food), "点所在的大类只会把小类改回大类")
    }

    func testSubcategoriesPutLearnedFirst() async throws {
        let backend = try await makeBackend()
        let dinner = try await category(backend, "晚餐")
        let food = try await category(backend, "饮食")
        try await spendAndPick(backend, at: "测试小馆", dinner.id)
        let next = try await spend(backend, at: "测试小馆")
        let id = try XCTUnwrap(next.recordID)
        let beforePick = try await backend.subcategorySuggestions(recordID: id)
        XCTAssertTrue(beforePick.isEmpty, "还没选大类")
        try await backend.setCategory(recordID: id, categoryID: food.id)
        let candidates = try await backend.subcategorySuggestions(recordID: id)
        XCTAssertEqual(candidates.first, dinner)
        XCTAssertEqual(candidates.count, CategoryLearner.notificationLimit)
        XCTAssertTrue(candidates.allSatisfy { $0.parentID == food.id })
    }

    func testNoSubcategoriesWhenThereIsNothingToRefine() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let daily = try await category(backend, "日用品")
        let first = try await spend(backend, at: "测试超市")
        let firstID = try XCTUnwrap(first.recordID)
        try await backend.setCategory(recordID: firstID, categoryID: daily.id)
        let noChildren = try await backend.subcategorySuggestions(recordID: firstID)
        XCTAssertTrue(noChildren.isEmpty, "这个大类没有小类")
        let second = try await spend(backend, at: "测试小馆")
        let secondID = try XCTUnwrap(second.recordID)
        try await backend.setCategory(recordID: secondID, categoryID: lunch.id)
        let alreadySmall = try await backend.subcategorySuggestions(recordID: secondID)
        XCTAssertTrue(alreadySmall.isEmpty, "已经是小类")
    }

    func testTwoStepPickCountsOnce() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let food = try await category(backend, "饮食")
        for round in 1...3 {
            let item = try await spend(backend, at: "测试小馆")
            let row = try await record(backend, item.recordID)
            XCTAssertNil(row.record.categoryID, "第 \(round) 笔还没选够")
            try await backend.setCategory(recordID: row.id, categoryID: food.id)
            try await backend.setCategory(recordID: row.id, categoryID: lunch.id)
        }
        let next = try await spend(backend, at: "测试小馆")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.record.categoryID, lunch.id)
        XCTAssertTrue(row.record.categoryAuto)
    }

    func testPickingOnlyTopLevelStillAutomates() async throws {
        let backend = try await makeBackend()
        let food = try await category(backend, "饮食")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试小馆", food.id) }
        let next = try await spend(backend, at: "测试小馆")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.record.categoryID, food.id)
        XCTAssertTrue(row.record.categoryAuto)
    }

    func testTopLevelPickKeepsStreakOfItsSubcategory() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let food = try await category(backend, "饮食")
        try await spendAndPick(backend, at: "测试小馆", lunch.id)
        try await spendAndPick(backend, at: "测试小馆", lunch.id)
        try await spendAndPick(backend, at: "测试小馆", food.id)
        try await spendAndPick(backend, at: "测试小馆", lunch.id)
        let next = try await spend(backend, at: "测试小馆")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.record.categoryID, lunch.id, "只选到大类不算改主意")
    }

    func testCorrectingInTwoStepsRestartsLearning() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let study = try await category(backend, "学习")
        let book = try await category(backend, "书")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试小馆", lunch.id) }
        let wrong = try await spend(backend, at: "测试小馆")
        let id = try XCTUnwrap(wrong.recordID)
        try await backend.setCategory(recordID: id, categoryID: study.id)
        try await backend.setCategory(recordID: id, categoryID: book.id)
        let next = try await spend(backend, at: "测试小馆")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.record.categoryID, "改掉之后重新学")
        let suggestions = try await backend.categorySuggestions(recordID: row.id)
        XCTAssertEqual(suggestions.categories.first, book)
        XCTAssertEqual(suggestions.topCategories.first, study)
    }

    // MARK: 现有规则不变

    func testUnconfirmedTransferIsOnlyRanked() async throws {
        let backend = try await makeBackend()
        let gift = try await category(backend, "人情")
        var id = ""
        for day in 1...5 {
            let text = "您尾号8810的账户10月1\(day)日10:00向张三转账\(day)00.00元【中国银行】"
            let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(Double(day) * 86_400)))
            id = try XCTUnwrap(result.items.first?.recordID)
            let row = try await record(backend, id)
            XCTAssertNil(row.category, "没确认对方的转账不自动归类")
            if day < 5 { try await backend.setCategory(recordID: id, categoryID: gift.id) }
        }
        let suggestions = try await backend.categorySuggestions(recordID: id)
        XCTAssertEqual(suggestions.categories.first?.id, gift.id)
        XCTAssertNil(suggestions.preferredID, "预先选好再点确定就成了转给别人，要用户自己选")
    }

    func testRulesStillComeFirst() async throws {
        let backend = try await makeBackend()
        let clothes = try await category(backend, "衣着")
        let gift = try await category(backend, "礼物")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试商城", gift.id) }
        let original = try await spend(backend, at: "测试商城")
        let originalID = try XCTUnwrap(original.recordID)
        try await backend.setCategory(recordID: originalID, categoryID: clothes.id)

        let refund = try await backend.ingest(IngestRequest(
            text: "您尾号8810的信用卡收到退款人民币\(10 + sequence).00元，商户：测试商城。【中国银行】", source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(86_400 * 30)
        ))
        let row = try await record(backend, refund.items.first?.recordID)
        XCTAssertEqual(row.category?.id, clothes.id, "退款跟着原交易")
        XCTAssertFalse(row.record.categoryAuto, "这是规则，不是学来的")
        let suggestions = try await backend.categorySuggestions(recordID: row.id)
        XCTAssertTrue(suggestions.categories.isEmpty, "已经有分类的不问")
    }

    func testTransferAndPendingHaveNoSuggestions() async throws {
        let backend = try await makeBackend()
        let result = try await backend.ingest(IngestRequest(text: "您尾号8810账户10月22日ATM取款500.00元，余额2,237.83元【中国银行】", source: .sms))
        let id = try XCTUnwrap(result.items.first?.recordID)
        let suggestions = try await backend.categorySuggestions(recordID: id)
        XCTAssertEqual(suggestions, CategorySuggestions(), "转帐不用选分类")

        let pending = try await backend.ingest(IngestRequest(text: "您尾号9999的卡消费人民币10.00元【中国银行】", source: .sms))
        XCTAssertNil(pending.items.first?.recordID, "待处理的还没有流水")
    }

    // MARK: 分类删除和合并

    func testMergingCategoriesKeepsWhatWasLearned() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试外卖", lunch.id) }
        try await backend.mergeCategory(id: lunch.id, into: dinner.id)

        let next = try await spend(backend, at: "测试外卖")
        let row = try await record(backend, next.recordID)
        XCTAssertEqual(row.category?.id, dinner.id, "合并是说这两个分类一样：学到的并过去，继续自动归类")
        XCTAssertTrue(row.record.categoryAuto)
    }

    func testMergingAddsUpPicksOfBothCategories() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        let dinner = try await category(backend, "晚餐")
        try await spendAndPick(backend, at: "测试外卖", dinner.id)
        for _ in 0..<2 { try await spendAndPick(backend, at: "测试外卖", lunch.id) }
        try await backend.mergeCategory(id: lunch.id, into: dinner.id)
        let next = try await spend(backend, at: "测试外卖")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category, "连续只有两次：合并不把次数凑上去")
        let suggestions = try await backend.categorySuggestions(recordID: row.id)
        XCTAssertEqual(suggestions.categories.first?.id, dinner.id)
    }

    func testDeletingCategoryWithTargetKeepsRankingButStopsAutomation() async throws {
        let backend = try await makeBackend()
        let daily = try await category(backend, "日用品")
        let other = try await category(backend, "其他")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试超市", daily.id) }
        try await backend.deleteCategory(id: daily.id, moveRecordsTo: other.id)

        let next = try await spend(backend, at: "测试超市")
        let row = try await record(backend, next.recordID)
        XCTAssertNil(row.category, "删掉的分类不再自动归类")
        let suggestions = try await backend.categorySuggestions(recordID: row.id)
        XCTAssertEqual(suggestions.categories.first?.id, other.id, "选过的记录跟着流水走")
    }

    func testDeletingCategoryWithoutTargetForgetsIt() async throws {
        let backend = try await makeBackend()
        let daily = try await category(backend, "日用品")
        for _ in 0..<3 { try await spendAndPick(backend, at: "测试超市", daily.id) }
        let auto = try await spend(backend, at: "测试超市")
        try await backend.deleteCategory(id: daily.id, moveRecordsTo: nil)

        let back = try await record(backend, auto.recordID)
        XCTAssertNil(back.category)
        XCTAssertFalse(back.record.categoryAuto, "回到待分类，不再是自动归类的")
        let suggestions = try await backend.categorySuggestions(recordID: back.id)
        XCTAssertNil(suggestions.preferredID, "这个商户学到的清掉了")
    }

    // MARK: 升级时回放

    func testSeedReplaysPastPicksOnce() async throws {
        let backend = try await makeBackend()
        let lunch = try await category(backend, "午餐")
        for _ in 0..<3 {
            let item = try await spend(backend, at: "测试外卖")
            let id = try XCTUnwrap(item.recordID)
            try await backend.database.write { try RecordDAO.setCategory($0, ids: [id], categoryID: lunch.id) }
        }
        let fee = try await backend.ingest(IngestRequest(text: "您尾号8810卡10月24日支出102.00元(含手续费2.00元)，商户：测试银行。【中国银行】", source: .sms))
        XCTAssertFalse(fee.items.isEmpty)

        let before = try await spend(backend, at: "测试外卖")
        let beforeRow = try await record(backend, before.recordID)
        XCTAssertNil(beforeRow.category, "老版本选的还没回放")

        try await backend.seedCategoryLearning()
        let after = try await spend(backend, at: "测试外卖")
        let afterRow = try await record(backend, after.recordID)
        XCTAssertEqual(afterRow.category?.id, lunch.id)

        let dinner = try await category(backend, "晚餐")
        try await backend.setCategory(recordID: afterRow.id, categoryID: dinner.id)
        try await backend.seedCategoryLearning()
        let again = try await spend(backend, at: "测试外卖")
        let againRow = try await record(backend, again.recordID)
        XCTAssertNil(againRow.category, "只回放一次，改掉的不会被老记录盖回去")
    }

    func testManualEntryWithMerchantCounts() async throws {
        let backend = try await makeBackend()
        let snack = try await category(backend, "饮料零食")
        let accounts = try await backend.accounts()
        let account = try XCTUnwrap(accounts.first)
        try await backend.addRecord(ManualEntry(
            type: .expense, accountID: account.id, amountMinor: 15_00, currency: .cny, categoryID: snack.id, counterparty: "测试奶茶", time: ParserSampleTests.reference
        ))
        let next = try await spend(backend, at: "测试奶茶")
        let suggestions = try await backend.categorySuggestions(recordID: try XCTUnwrap(next.recordID))
        XCTAssertEqual(suggestions.preferredID, snack.id)
    }

    func testIngestItemCarriesRecordID() async throws {
        let backend = try await makeBackend()
        let item = try await spend(backend, at: "测试外卖")
        XCTAssertNotNil(item.recordID)
        let row = try await record(backend, item.recordID)
        XCTAssertEqual(row.record.counterparty, "测试外卖")
    }
}
