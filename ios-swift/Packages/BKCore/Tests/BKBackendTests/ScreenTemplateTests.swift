import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 截图模板（ADR 0028）。页面是编的：App、商户、卡号、单号都不是真的。
/// 文字照 `ScreenLayout.text` 的样子写：一行里各段用两个空格隔开
final class ScreenTemplateTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: hour, minute: minute, second: second))!
    }

    /// 通用读法认不出的页面：没有「支付成功」「付款方式」这些字
    let walletPage = """
    9:41
    示例钱包
    交易结果
    消费成功
    -23.50
    商户  示例小馆
    扣款账户  示例银行借记卡(0427)
    交易时间  2026-10-24 12:30
    订单编号  12345678901234
    完成
    """

    let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [
        .amount: .init(row: 4, column: 0),
        .counterparty: .init(row: 5, column: 1),
        .cardTail: .init(row: 6, column: 1),
    ]

    func makeTemplate(_ text: String, picks: [ScreenTemplateField.Role: ScreenTemplates.Cell], kind: TransactionKind = .purchase,
                      direction: FlowDirection = .outflow, accountID: String? = nil) throws -> ScreenTemplate {
        let built = try ScreenTemplates.build(text: text, picks: picks).get()
        return ScreenTemplate(
            id: UUID().uuidString, name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: kind, direction: direction,
            accountID: accountID, createdAt: now
        )
    }

    func testBuildKeepsFixedWordsAndNoNumbers() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        XCTAssertEqual(template.anchors, ["示例钱包", "交易结果", "消费成功", "商户", "扣款账户", "交易时间", "订单编号", "完成"])
        XCTAssertFalse(template.anchors.joined().contains { $0.isNumber }, "不保存截图上的数字")
        XCTAssertEqual(template.field(.amount), ScreenTemplateField(role: .amount, anchor: "消费成功", place: .below))
        XCTAssertEqual(template.field(.counterparty), ScreenTemplateField(role: .counterparty, anchor: "商户", place: .right))
        XCTAssertEqual(template.field(.cardTail), ScreenTemplateField(role: .cardTail, anchor: "扣款账户", place: .right))
    }

    func testMatchesTheSamePageWithOtherValuesAndAnAd() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        // 对勾认成了「•」，多了一条广告，卡号和标签认成了一段，时间、单号换了
        let other = """
        10:02
        示例钱包
        交易结果
        • 消费成功
        -99.00
        领 8.88 元红包  立即领取
        商户  另一家店
        扣款账户 示例银行借记卡(1111)
        交易时间  2026-10-25 08:01
        订单编号  99999999999999
        完成
        """
        let hit = try XCTUnwrap(ScreenTemplates.match(template, text: other))
        XCTAssertEqual(hit.amount.digits, "99.00")
        XCTAssertEqual(hit.counterparty, "另一家店")
        XCTAssertEqual(hit.cardTail, "1111")
    }

    func testDoesNotMatchAnotherPage() throws {
        let template = try makeTemplate(walletPage, picks: picks)
        let other = "9:41\n示例商城\n订单详情\n¥12.00\n收货地址  示例路\n完成"
        XCTAssertNil(ScreenTemplates.match(template, text: other))
    }

    func testBuildNeedsAnAmountAndEnoughWords() {
        XCTAssertEqual(ScreenTemplates.build(text: walletPage, picks: [:]).failure, .missingAmount)
        XCTAssertEqual(ScreenTemplates.build(text: walletPage, picks: [.amount: .init(row: 1, column: 0)]).failure, .invalidAmount)
        XCTAssertEqual(ScreenTemplates.build(text: "完成\n12.00", picks: [.amount: .init(row: 1, column: 0)]).failure, .tooGeneric)
    }

    func testScreenTemplateRecordsAPageTheParserCannotRead() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let before = try await backend.ingestScreenshot(text: walletPage, capturedAt: at(12, 31))
        XCTAssertEqual(before.outcome, .filtered, "没有模板时认不出")

        _ = try await backend.saveScreenTemplate(try makeTemplate(walletPage, picks: picks))
        let result = try await backend.ingestScreenshot(text: walletPage, capturedAt: at(12, 31))
        XCTAssertEqual(result.recordedCount, 1)
        let rows = try await backend.records(accountID: card.id)
        let record = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(record.amountMinor, 2350)
        XCTAssertEqual(record.direction, .outflow)
        XCTAssertEqual(record.counterparty, "示例小馆")
    }

    /// 记到选的账户（余额宝），截图上的卡是另一边：先算收入，卡上那笔来了合成转帐
    func testFixedAccountWithTheOtherCardPairsIntoATransfer() async throws {
        let backend = try makeBackend()
        let yuebao = try await backend.addAccount(.pocket(name: "余额宝", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        let page = "示例理财\n存入成功\n¥5.00\n转出卡  示例银行借记卡(0427)\n完成"
        let template = try makeTemplate(
            page, picks: [.amount: .init(row: 2, column: 0), .cardTail: .init(row: 3, column: 1)],
            kind: .transferIn, direction: .inflow, accountID: yuebao.id
        )
        _ = try await backend.saveScreenTemplate(template)
        _ = try await backend.ingestScreenshot(text: page, capturedAt: at(13, 1))
        let sms = "您账户0427于10月24日13:00在【支付宝-余额宝】发生快捷支付扣款，人民币5.00"
        _ = try await backend.ingest(IngestRequest(text: sms, source: .auto, receivedAt: at(13, 0, 30)))
        let intoRows = try await backend.records(accountID: yuebao.id)
        let outRows = try await backend.records(accountID: card.id)
        let into = try XCTUnwrap(intoRows.first?.record)
        let out = try XCTUnwrap(outRows.first?.record)
        XCTAssertEqual(into.kind, .transferIn)
        XCTAssertNotNil(into.transferGroupID)
        XCTAssertEqual(into.transferGroupID, out.transferGroupID)
    }

    func testSavingATemplateRereadsOpenScreenshotPending() async throws {
        let backend = try makeBackend()
        let card = try await backend.addAccount(AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean"))
        // 像付款页（「付款方式」），看不出是付出去还是收进来：进待处理
        let page = "示例钱包\n¥8.00\n付款方式  示例银行借记卡(0427)\n完成"
        let first = try await backend.ingestScreenshot(text: page, capturedAt: at(14, 0))
        XCTAssertEqual(first.pendingCount, 1)
        let ingestID = try XCTUnwrap(first.ingestID)
        let pendingBefore = try await backend.hasOpenPending(ingestID: ingestID)
        XCTAssertTrue(pendingBefore)

        let template = try makeTemplate(page, picks: [.amount: .init(row: 1, column: 0), .cardTail: .init(row: 2, column: 1)])
        let count = try await backend.saveScreenTemplate(template)
        XCTAssertEqual(count, 1)
        let pendingAfter = try await backend.hasOpenPending(ingestID: ingestID)
        XCTAssertFalse(pendingAfter)
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.first?.record.amountMinor, 800)
    }

    func testLayoutKeepsSegmentsApart() {
        let lines = [
            ScreenTextLine(text: "付款方式", x: 0.05, y: 0.5, width: 0.2, height: 0.02),
            ScreenTextLine(text: "示例银行  借记卡(0427)", x: 0.5, y: 0.5, width: 0.45, height: 0.02),
            ScreenTextLine(text: "¥8.00", x: 0.4, y: 0.3, width: 0.2, height: 0.04),
        ]
        XCTAssertEqual(ScreenLayout.text(lines), "¥8.00\n付款方式  示例银行 借记卡(0427)", "一段里的空白缩成一个，段和段之间两个空格")
        XCTAssertEqual(ScreenTemplates.page(ScreenLayout.text(lines)).map(\.count), [1, 2])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
