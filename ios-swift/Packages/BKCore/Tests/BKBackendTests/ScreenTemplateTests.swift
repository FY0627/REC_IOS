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

    // MARK: 小图标拆开

    /// 一段字在截图上每一列有没有字：`blobs` 是一团一团的字（从第几列到第几列、上下边），其余的列空着
    func ink(width: Int, _ blobs: [(ClosedRange<Int>, ClosedRange<Int>)]) -> [ClosedRange<Int>?] {
        (0..<width).map { x in blobs.first { $0.0.contains(x) }?.1 }
    }

    func testSmallIconAtTheEndBecomesItsOwnSegment() {
        // 「+ ¥0.63 ⓘ」认成「+￥0.630」：「+」、「¥0.63」（40 像素高）、隔开 14 像素的 ⓘ（18 像素高）
        let line = ScreenTextLine(text: "+￥0.630", x: 0.3, y: 0.2, width: 0.3, height: 0.04)
        let columns = ink(width: 300, [(0...20, 15...35), (40...230, 5...44), (245...262, 16...33)])
        let parts = ScreenLayout.splitIcons(line, ink: columns)
        XCTAssertEqual(parts.map(\.text), ["+￥0.63", "0"])
        XCTAssertEqual(ScreenLayout.text(parts), "+￥0.63  0", "拆开的还在同一行")
        XCTAssertEqual(parts[1].x, 0.3 + 0.3 * 245 / 300, accuracy: 0.0001)
    }

    func testSameHeightWordsPunctuationAndSignsStayTogether() {
        let words = ScreenTextLine(text: "付款方式 招商", x: 0.1, y: 0.5, width: 0.4, height: 0.03)
        let wordInk = ink(width: 200, [(0...110, 0...29), (130...190, 0...29)])
        XCTAssertEqual(ScreenLayout.splitIcons(words, ink: wordInk), [words], "一样高的字中间空一格不拆")

        let done = ScreenTextLine(text: "完成了。", x: 0.1, y: 0.5, width: 0.2, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(done, ink: ink(width: 120, [(0...90, 0...29), (100...106, 22...29)])), [done], "小的标点不拆")

        let sign = ScreenTextLine(text: "+12.00", x: 0.1, y: 0.5, width: 0.2, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(sign, ink: ink(width: 120, [(0...10, 10...20), (25...110, 0...29)])), [sign], "正负号不拆")

        let wide = ScreenTextLine(text: "收益 abc", x: 0.1, y: 0.5, width: 0.3, height: 0.03)
        XCTAssertEqual(ScreenLayout.splitIcons(wide, ink: ink(width: 200, [(0...60, 0...29), (80...150, 10...25)])).count, 1, "矮一截但很宽的（一串小字）不拆")
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

    // MARK: 版面骨架

    /// 按页面文字排出截图上的段：一行一行往下，一行里各段从左往右
    func lines(_ page: String) -> [ScreenTextLine] {
        ScreenTemplates.page(page).enumerated().flatMap { r, row in
            row.enumerated().map { c, text in
                ScreenTextLine(text: text, x: 0.05 + Double(c) * 0.45, y: 0.02 + Double(r) * 0.06, width: 0.4, height: 0.03)
            }
        }
    }

    func testSkeletonHidesNumbersAndRebuildsTheSameTemplate() throws {
        let original = lines(walletPage)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 1179.0 / 2556)
        let text = ScreenLayout.text(layout.lines)
        XCTAssertEqual(text, """
        0:00
        示例钱包
        交易结果
        消费成功
        -100.00
        商户  对方
        扣款账户  示例银行借记卡(1234)
        交易时间  0000-00-00 00:00
        订单编号  00000000000000
        完成
        """)
        XCTAssertEqual(layout.aspect, 0.4613)
        XCTAssertEqual(layout.lines.count, original.count)

        let template = ScreenTemplate(
            id: "t", name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: .purchase, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        XCTAssertEqual(ScreenTemplates.picks(for: template, in: text), picks, "在骨架上找回原来点的几段")
        let rebuilt = try ScreenTemplates.build(text: text, picks: picks).get()
        XCTAssertEqual(rebuilt.anchors, built.anchors)
        XCTAssertEqual(rebuilt.fields, built.fields)
        let hit = try XCTUnwrap(ScreenTemplates.match(template, text: text))
        XCTAssertEqual(hit.amount.digits, "100.00")
        XCTAssertEqual(hit.cardTail, "1234")
        XCTAssertEqual(hit.counterparty, "对方")
    }

    func testSkeletonWhenLabelAndValueAreOneSegment() throws {
        let page = """
        示例钱包
        转账成功
        ¥0.01
        收款方 示例小馆
        付款方式 示例银行借记卡(0427)
        完成
        """
        let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [
            .amount: .init(row: 2, column: 0), .counterparty: .init(row: 3, column: 0), .cardTail: .init(row: 4, column: 0),
        ]
        let original = lines(page)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 0.5)
        let text = ScreenLayout.text(layout.lines)
        XCTAssertEqual(ScreenTemplates.page(text)[2], ["¥100.00"])
        // 标签只在点到的这一段里，不是固定的字：整段就是对方
        XCTAssertEqual(ScreenTemplates.page(text)[3], ["对方"])
        XCTAssertEqual(ScreenTemplates.page(text)[4], ["付款方式 示例银行借记卡(1234)"])
        let template = ScreenTemplate(
            id: "t", name: "示例", anchors: built.anchors, fields: built.fields, kind: .transferOut, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        XCTAssertEqual(ScreenTemplates.picks(for: template, in: text), picks)
    }

    /// 金额旁边的「ⓘ」认成了一位数字，紧跟在金额后面（「+￥0.630」）：多的这一位不算
    func testIconNextToTheAmountReadAsADigit() throws {
        let page = """
        0:30
        交易详情
        示例汇率补贴
        +￥0.630
        余额￥0.63
        交易卡号  示例卡 0000********3442
        交易类型  境外消费退款
        """
        let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [.amount: .init(row: 3, column: 0)]
        let built = try ScreenTemplates.build(text: page, picks: picks).get()
        XCTAssertEqual(built.fields.first?.anchor, "示例汇率补贴")
        let template = ScreenTemplate(
            id: "t", name: "示例", anchors: built.anchors, fields: built.fields, kind: .refund, direction: .inflow, accountID: nil, createdAt: now
        )
        let other = page.replacingOccurrences(of: "+￥0.630", with: "+￥25.000").replacingOccurrences(of: "余额￥0.63", with: "余额￥25.63")
        XCTAssertEqual(ScreenTemplates.match(template, text: other)?.amount.digits, "25.00")

        XCTAssertNil(ScreenTemplates.amount(in: "6.8235"), "没有 ¥ 的多位小数（汇率）不算")
        XCTAssertNil(ScreenTemplates.amount(in: "+1.0958%"))

        let layout = ScreenTemplates.skeleton(lines(page), picks: picks, fields: built.fields, aspect: 0.5)
        XCTAssertEqual(ScreenTemplates.page(ScreenLayout.text(layout.lines))[3], ["+¥100.00"])
    }

    func testSavedTemplateKeepsItsLayout() async throws {
        let backend = try makeBackend()
        let original = lines(walletPage)
        let built = try ScreenTemplates.build(text: ScreenLayout.text(original), picks: picks).get()
        let layout = ScreenTemplates.skeleton(original, picks: picks, fields: built.fields, aspect: 0.5)
        var template = ScreenTemplate(
            id: "t", name: "示例钱包", anchors: built.anchors, fields: built.fields, kind: .purchase, direction: .outflow,
            accountID: nil, createdAt: now, layout: layout
        )
        _ = try await backend.saveScreenTemplate(template)
        template.name = "改过的名称"
        _ = try await backend.saveScreenTemplate(template)
        let saved = try await backend.screenTemplates()
        XCTAssertEqual(saved.count, 1, "按原来的标识改，不多出一个")
        XCTAssertEqual(saved.first?.name, "改过的名称")
        XCTAssertEqual(saved.first?.layout, layout)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
