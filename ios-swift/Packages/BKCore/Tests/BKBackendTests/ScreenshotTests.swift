import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 付款页截图记账（ADR 0021）。页面文字照微信、支付宝的版式自己写的：商户、人名、单号都是编的，不是真实截图
final class ScreenshotTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference // 2026-10-24 16:00 +08:00

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 24) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    @discardableResult
    func addWechat(_ backend: LedgerBackend, name: String = "微信零钱") async throws -> Account {
        try await backend.addAccount(.pocket(name: name, type: .wallet, currency: .cny, paletteID: "jade", walletID: "wechatpay"))
    }

    @discardableResult
    func addAlipay(_ backend: LedgerBackend, name: String = "支付宝余额") async throws -> Account {
        try await backend.addAccount(.pocket(name: name, type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
    }

    @discardableResult
    func addCard(_ backend: LedgerBackend, last4: String = "0427", bank: String = "cmb", bankName: String = "招商银行", type: CardType = .debit) async throws -> Account {
        try await backend.addAccount(AccountDraft(name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: .cny, paletteID: "ocean"))
    }

    // MARK: 页面

    /// 微信账单详情（零钱付）
    let wechatDetail = """
    15:02
    <
    示例便利店
    -12.00
    当前状态  支付成功
    支付时间  2026年10月24日 14:30:45
    商品  示例便利店消费
    商户全称  示例连锁管理有限公司
    收单机构  财付通支付科技有限公司
    支付方式  零钱
    交易单号  4200000000202610240000000001
    商户单号  20261024000001
    """

    /// 微信扫码付款后的成功页：没写用什么付的
    let wechatSuccess = """
    14:31
    支付成功
    ¥12.00
    示例便利店
    完成
    """

    /// 微信账单详情（银行卡付）
    let wechatCardDetail = """
    示例面馆
    -26.00
    当前状态  支付成功
    支付时间  2026年10月24日 14:30:45
    收单机构  财付通支付科技有限公司
    支付方式  招商银行储蓄卡(0427)
    交易单号  4200000000202610240000000002
    """

    /// 微信转账详情（转出）
    let wechatTransferOut = """
    转账-转给张三
    -100.00
    当前状态  对方已收钱
    转账时间  2026年10月24日 12:05:10
    收款时间  2026年10月24日 12:06:00
    支付方式  零钱
    转账单号  1000050000202610240000000003
    """

    /// 微信转账详情（收到）
    let wechatTransferIn = """
    转账-来自李四
    +88.00
    当前状态  已存入零钱
    转账时间  2026年10月24日 09:00:00
    收款时间  2026年10月24日 09:10:00
    转账单号  1000050000202610240000000004
    """

    /// 聊天里点开转账：转给别人、对方收了以后（照真机截图的版式，名字、金额、时间换过）
    let wechatTransferAccepted = """
    14:32
    71
    示例老板已收款
    ¥192.00
    转账时间  2026年10月24日 12:08:40
    收款时间  2026年10月24日 13:12:28
    账单详情
    """

    /// 聊天里点开转账：别人转给自己、收了以后
    let wechatTransferReceived = """
    21:19
    66
    你已收款，资金已存入零钱
    ¥339.00
    零钱余额
    转账时间  2026年10月24日 09:31:35
    收款时间  2026年10月24日 11:06:51
    账单详情
    """

    /// 聊天里领到的红包
    let wechatRedPacket = """
    王五的红包
    6.66元
    已存入零钱，可直接消费
    """

    /// 新版红包页：发红包的人下面一行是祝福语
    let wechatRedPacketWithGreeting = """
    示例阿明发出红包
    恭喜发财，大吉大利
    8.88元
    已存入零钱，可直接消费＞
    """

    /// 写成「发出的红包」的：钱存进了自己的零钱，是收到的
    let wechatRedPacketSentBy = """
    示例阿芳发出的红包
    恭喜发财，大吉大利
    5.20元
    已存入零钱，可直接消费＞
    """

    /// 支付宝账单详情（余额付）
    let alipayDetail = """
    示例外卖
    -35.50
    交易成功
    支付时间  2026-10-24 11:45:20
    付款方式  余额
    商品说明  外卖订单
    收款方全称  示例科技有限公司
    账单分类  餐饮美食
    订单号  2026102422001400000000000005
    商家订单号  1700000000000000000
    """

    /// 支付宝用花呗付
    let alipayHuabei = """
    示例超市
    -58.00
    交易成功
    支付时间  2026-10-24 10:20:00
    付款方式  花呗
    订单号  2026102422001400000000000006
    """

    // MARK: 排成行

    func testLinesOnTheSameRowAreJoinedLeftToRight() {
        let lines = [
            ScreenTextLine(text: "零钱", x: 0.70, y: 0.502, width: 0.10, height: 0.02),
            ScreenTextLine(text: "-12.00", x: 0.40, y: 0.20, width: 0.20, height: 0.05),
            ScreenTextLine(text: "支付方式", x: 0.05, y: 0.50, width: 0.20, height: 0.02),
            ScreenTextLine(text: "示例便利店", x: 0.35, y: 0.12, width: 0.30, height: 0.03),
        ]
        XCTAssertEqual(ScreenLayout.rows(lines), ["示例便利店", "-12.00", "支付方式  零钱"])
    }

    func testRowsFromLinesAreRecorded() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        let lines = [
            ScreenTextLine(text: "示例便利店", x: 0.35, y: 0.10, width: 0.30, height: 0.03),
            ScreenTextLine(text: "-12.00", x: 0.40, y: 0.16, width: 0.20, height: 0.05),
            ScreenTextLine(text: "支付方式", x: 0.05, y: 0.40, width: 0.20, height: 0.02),
            ScreenTextLine(text: "零钱", x: 0.70, y: 0.401, width: 0.10, height: 0.02),
            ScreenTextLine(text: "支付时间", x: 0.05, y: 0.45, width: 0.20, height: 0.02),
            ScreenTextLine(text: "2026年10月24日 14:30:45", x: 0.50, y: 0.452, width: 0.40, height: 0.02),
        ]
        let result = try await backend.ingestScreenshot(lines: lines, capturedAt: now)
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let record = try await backend.records(accountID: wallet.id)[0].record
        XCTAssertEqual(record.counterparty, "示例便利店")
        XCTAssertEqual(record.amountMinor, 12_00)
    }

    // MARK: 认页面、入账

    func testWechatDetailIsRecordedToTheWechatWallet() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        let result = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: now)
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, wallet.id)
        XCTAssertEqual(r.amountMinor, 12_00)
        XCTAssertEqual(r.currency, .cny)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.counterparty, "示例便利店", "用页面标题，不用商户全称")
        XCTAssertEqual(r.source, .screenshot)
        XCTAssertEqual(r.bankReference, "4200000000202610240000000001")
        XCTAssertEqual(r.transactionTime?.sortKey, "2026-10-24T14:30:45")
        XCTAssertEqual(r.effectiveAt, at(14, 30, 45), "按页面上的交易时间排，不按截图的时间")
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.accountTitle, "微信零钱")
        XCTAssertEqual(item.counterparty, "示例便利店")
    }

    func testSuccessPageWithoutMethodGoesToTheOnlyWallet() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        let result = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, wallet.id)
        XCTAssertEqual(r.counterparty, "示例便利店")
        XCTAssertEqual(r.amountMinor, 12_00)
        XCTAssertNil(r.transactionTime)
        XCTAssertEqual(r.effectiveAt, at(14, 31), "成功页没写时间：用截图的时间")
    }

    func testSuccessPageWithTwoWalletsAsksWhichOne() async throws {
        let backend = try makeBackend()
        let wechat = try await addWechat(backend)
        let alipay = try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        XCTAssertEqual(result.pendingCount, 1)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .ambiguousAccount)
        XCTAssertEqual(Set(item.candidateAccountIDs), [wechat.id, alipay.id])
    }

    func testCardPaymentIsRecordedToTheCard() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let card = try await addCard(backend)
        let result = try await backend.ingestScreenshot(text: wechatCardDetail, capturedAt: now)
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, card.id)
        XCTAssertEqual(r.counterparty, "示例面馆")
    }

    func testTransfersAndRedPackets() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatTransferOut, capturedAt: now)
        _ = try await backend.ingestScreenshot(text: wechatTransferIn, capturedAt: now)
        _ = try await backend.ingestScreenshot(text: wechatRedPacket, capturedAt: at(15, 0))
        let rows = try await backend.records(accountID: wallet.id).map(\.record)
        XCTAssertEqual(rows.count, 3)
        let out = try XCTUnwrap(rows.first { $0.amountMinor == 100_00 })
        XCTAssertEqual(out.kind, .transferOut)
        XCTAssertEqual(out.direction, .outflow)
        XCTAssertEqual(out.counterparty, "张三")
        XCTAssertEqual(out.transactionTime?.sortKey, "2026-10-24T12:05:10", "转出看转账时间")
        let into = try XCTUnwrap(rows.first { $0.amountMinor == 88_00 })
        XCTAssertEqual(into.kind, .transferIn)
        XCTAssertEqual(into.direction, .inflow)
        XCTAssertEqual(into.counterparty, "李四")
        XCTAssertEqual(into.transactionTime?.sortKey, "2026-10-24T09:10:00", "收到的看收款时间")
        let packet = try XCTUnwrap(rows.first { $0.amountMinor == 6_66 })
        XCTAssertEqual(packet.kind, .income)
        XCTAssertEqual(packet.direction, .inflow)
        XCTAssertEqual(packet.counterparty, "王五")
    }

    func testRedPacketWithGreetingIsFromTheSender() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatRedPacketWithGreeting, capturedAt: at(15, 0))
        _ = try await backend.ingestScreenshot(text: wechatRedPacketSentBy, capturedAt: at(15, 30))
        let rows = try await backend.records(accountID: wallet.id).map(\.record)
        XCTAssertEqual(rows.count, 2)
        for (minor, name) in [(8_88, "示例阿明"), (5_20, "示例阿芳")] {
            let packet = try XCTUnwrap(rows.first { $0.amountMinor == Int64(minor) }, name)
            XCTAssertEqual(packet.kind, .income, name)
            XCTAssertEqual(packet.direction, .inflow, "已存入零钱：是收到的红包，不看「发出的红包」")
            XCTAssertEqual(packet.counterparty, name, "祝福语不是对方")
        }
    }

    func testTransferPageSaysWhoReceivedTheMoney() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatTransferAccepted, capturedAt: at(14, 32))
        _ = try await backend.ingestScreenshot(text: wechatTransferReceived, capturedAt: at(15, 19))
        let rows = try await backend.records(accountID: wallet.id).map(\.record)
        XCTAssertEqual(rows.count, 2)
        let out = try XCTUnwrap(rows.first { $0.amountMinor == 192_00 })
        XCTAssertEqual(out.direction, .outflow, "「示例老板已收款」：对方收了，是自己转出去的")
        XCTAssertEqual(out.kind, .transferOut)
        XCTAssertEqual(out.counterparty, "示例老板")
        XCTAssertEqual(out.transactionTime?.sortKey, "2026-10-24T12:08:40", "转出看转账时间")
        let into = try XCTUnwrap(rows.first { $0.amountMinor == 339_00 })
        XCTAssertEqual(into.direction, .inflow)
        XCTAssertEqual(into.kind, .transferIn)
        XCTAssertNil(into.counterparty, "自己收的页面上没写对方，标题和「零钱余额」都不是")
        XCTAssertEqual(into.transactionTime?.sortKey, "2026-10-24T11:06:51", "收到的看收款时间")
    }

    func testPendingTransferTitles() {
        func direction(_ title: String) -> FlowDirection? {
            let text = "\(title)\n¥50.00\n转账时间  2026年10月24日 12:00:00"
            return ScreenshotParser.parse(text, referenceDate: now, calendar: calendar).message.events.first?.draft.direction
        }
        XCTAssertEqual(direction("待示例老板确认收款"), .outflow)
        XCTAssertEqual(direction("待你收款"), .inflow)
        XCTAssertEqual(direction("对方已收款"), .outflow)
        XCTAssertEqual(direction("你已收款,资金已存入零钱"), .inflow)
    }

    func testAlipayDetailGoesToTheAlipayWallet() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let alipay = try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: alipayDetail, capturedAt: now)
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, alipay.id)
        XCTAssertEqual(r.amountMinor, 35_50)
        XCTAssertEqual(r.counterparty, "示例外卖")
        XCTAssertEqual(r.bankReference, "2026102422001400000000000005")
    }

    func testHuabeiNeedsItsOwnAccount() async throws {
        let backend = try makeBackend()
        let balance = try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: alipayHuabei, capturedAt: now)
        XCTAssertEqual(result.pendingCount, 1, "花呗是借的钱，不记到余额里")
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .noWalletAccount)
        let count = try await backend.recordCount(accountID: balance.id)
        XCTAssertEqual(count, 0)
        // 加了名称里有「花呗」的账户：自动记上
        let huabei = try await backend.addAccount(AccountDraft(name: "花呗", bankID: nil, bankName: "花呗", last4: "0000", cardType: .credit, currency: .cny, paletteID: "ocean"))
        let records = try await backend.records(accountID: huabei.id)
        XCTAssertEqual(records.count, 1)
    }

    func testWithoutWalletWaitsUntilItIsAdded() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: now)
        XCTAssertEqual(result.pendingCount, 1)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .noWalletAccount)
        XCTAssertEqual(result.items.first?.accountTitle, "微信支付")
        let wallet = try await addWechat(backend)
        let count = try await backend.recordCount(accountID: wallet.id)
        XCTAssertEqual(count, 1, "添加钱包后自动记上")
        let open = try await backend.openPendingItems()
        XCTAssertTrue(open.isEmpty)
    }

    func testNonPaymentScreenshotIsNotSaved() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let chat = try await backend.ingestScreenshot(text: "15:02\n张三\n晚上一起吃饭吗\n好的", capturedAt: now)
        XCTAssertEqual(chat.outcome, .filtered)
        let price = try await backend.ingestScreenshot(text: "商品详情\n¥199.00\n加入购物车", capturedAt: now)
        XCTAssertEqual(price.outcome, .filtered, "有价格但不是付款页")
        let log = try await backend.ingestLog()
        XCTAssertTrue(log.isEmpty)
        let pending = try await backend.openPendingItems()
        XCTAssertTrue(pending.isEmpty)
    }

    func testPaymentPageWithoutAmountGoesToPending() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let result = try await backend.ingestScreenshot(text: "支付成功\n示例便利店\n完成", capturedAt: now)
        XCTAssertEqual(result.pendingCount, 1)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .unrecognized)
        XCTAssertNotNil(item.rawText, "原文留着，可以拷出来")
    }

    func testOwnMovesBetweenChangeAndLingqiantongAreSkipped() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let result = try await backend.ingestScreenshot(text: "零钱通转出-到零钱\n56.07\n当前状态  已到账", capturedAt: now)
        XCTAssertEqual(result.outcome, .filtered)
    }

    func testWithdrawalPairsWithTheCard() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        let card = try await addCard(backend)
        _ = try await backend.ingestScreenshot(text: "零钱提现-到招商银行(0427)\n-200.00\n当前状态  已到账\n提现时间  2026年10月24日 13:00:00\n到账银行  招商银行(0427)", capturedAt: now)
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0427的储蓄卡10月24日13:00财付通提现收入人民币200.00元", source: .auto, receivedAt: at(13, 0, 30)))
        let out = try await backend.records(accountID: wallet.id)[0].record
        XCTAssertEqual(out.kind, .transferOut)
        let into = try await backend.records(accountID: card.id)[0].record
        XCTAssertNotNil(out.transferGroupID)
        XCTAssertEqual(out.transferGroupID, into.transferGroupID, "零钱提现和到卡的那笔配成转帐")
    }

    // MARK: 页面上没有「微信」「零钱」的微信页（照真机截图的版式，名字、卡号、单号、时间换过）

    /// 微信收款商业版：经营账户提现到银行卡
    let wechatBusinessWithdrawal = """
    13:02
    <
    经营账户提现-到建设银行(0005)
    -650.00
    当前状态  到账成功
    申请时间  2026年10月24日 13:00:02
    到账时间  2026年10月24日 13:00:04
    提现银行  建设银行(0005)
    提现单号  2091000000000000000000000
    00001
    服务费 ⓘ  ¥0.00  ¥0.65
    提现免费额度减免0.65元
    经营账户余  ¥0.00
    额
    """

    /// 微信收款商业版：顾客转账付给店铺，存进经营账户
    let wechatBusinessReceipt = """
    9:12
    <  全部收款明细
    示例顾客
    +650.00
    该顾客累计消费2次(捧场老客)  >
    收款店铺  示例小店
    收款方式  转账收款
    聊天位置  示例群聊
    当前状态  已存入经营账户
    收款时间  2026年10月24日 09:06:33
    收款单号  1000000000202610240000000007
    联系顾客  退款  帮助中心
    """

    /// 聊天里点开转账：只有「谁已收款」、金额和两个时间
    let wechatPlainTransfer = """
    10:23
    <
    ...
    示例朋友已收款
    ¥12.50
    转账时间  2026年10月24日 13:24:25
    收款时间  2026年10月24日 13:53:01
    账单详情
    """

    func testBusinessWithdrawalGoesToWechatAndPairsWithTheCard() async throws {
        let backend = try makeBackend()
        let wechat = try await addWechat(backend)
        try await addAlipay(backend)
        let card = try await addCard(backend, last4: "0005", bank: "ccb", bankName: "建设银行")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0005的储蓄卡10月24日13时00分财付通提现收入人民币650.00元,活期余额1650.00元。[建设银行]", source: .auto, receivedAt: at(13, 0, 30)))
        let result = try await backend.ingestScreenshot(text: wechatBusinessWithdrawal, capturedAt: at(13, 2))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let out = try await backend.records(accountID: wechat.id)[0].record
        XCTAssertEqual(out.kind, .transferOut)
        XCTAssertEqual(out.amountMinor, 650_00)
        XCTAssertEqual(out.bankReference, "209100000000000000000000000001", "换行的单号接上")
        XCTAssertEqual(out.transactionTime?.sortKey, "2026-10-24T13:00:04", "看到账时间")
        let into = try await backend.records(accountID: card.id)[0].record
        XCTAssertNotNil(out.transferGroupID)
        XCTAssertEqual(out.transferGroupID, into.transferGroupID, "经营账户提现和到卡的那笔配成转帐")
    }

    func testBusinessAccountWithItsOwnWalletIsUsed() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let business = try await addWechat(backend, name: "经营账户")
        try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: wechatBusinessReceipt, capturedAt: at(9, 12))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let count = try await backend.recordCount(accountID: business.id)
        XCTAssertEqual(count, 1, "有名称里有「经营账户」的账户时记到它")
    }

    func testBusinessReceiptIsIncomeToWechat() async throws {
        let backend = try makeBackend()
        let wechat = try await addWechat(backend)
        try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: wechatBusinessReceipt, capturedAt: at(9, 12))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records(accountID: wechat.id)[0].record
        XCTAssertEqual(r.direction, .inflow)
        XCTAssertEqual(r.kind, .income, "顾客付给店铺的钱是收入；底部的「退款」是按钮，不是退款")
        XCTAssertEqual(r.counterparty, "示例顾客")
        XCTAssertEqual(r.transactionTime?.sortKey, "2026-10-24T09:06:33")
        XCTAssertEqual(r.bankReference, "1000000000202610240000000007")

        func kind(_ text: String) -> TransactionKind? {
            ScreenshotParser.parse(text, referenceDate: now, calendar: calendar).message.events.first?.draft.kind
        }
        XCTAssertEqual(kind(wechatBusinessReceipt.replacingOccurrences(of: "联系顾客  退款  帮助中心", with: "联系顾客｜退款｜帮助中心")), .income)
        XCTAssertEqual(kind("示例便利店\n+12.00\n当前状态  已全额退款\n退款时间  2026年10月24日 15:00:00\n退款方式  退回零钱"), .refund)
    }

    func testPlainTransferPageGoesToWechat() async throws {
        let backend = try makeBackend()
        let wechat = try await addWechat(backend)
        try await addAlipay(backend)
        let result = try await backend.ingestScreenshot(text: wechatPlainTransfer, capturedAt: at(14, 23))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let r = try await backend.records(accountID: wechat.id)[0].record
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .transferOut)
        XCTAssertEqual(r.counterparty, "示例朋友")
        XCTAssertEqual(r.amountMinor, 12_50)

        // 标题只认出名字、没有「已收款」：「转账时间」「收款时间」都有的也是微信
        let nameOnly = wechatPlainTransfer.replacingOccurrences(of: "示例朋友已收款", with: "示例朋友")
        XCTAssertEqual(ScreenshotParser.parse(nameOnly, referenceDate: now, calendar: calendar).message.walletHint, "wechatpay")
    }

    /// 支付宝转给别人、别人转给自己的账单详情（照真机截图的版式）：认微信的改动不影响它们
    func testAlipayTransfersStillGoToAlipay() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        let alipay = try await addAlipay(backend)
        let tail = """
        转账备注  转账
        对方账户  示例好友 138******00
        更多
        账单管理  我的消费图鉴  >
        账单分类  转账红包  >
        标签  请选择  >
        为您推荐  转账红包  +
        计入收支
        备注  添加  >
        """
        let sent = "10:25\n<  账单详情  全部账单\n示例好友\n-51.00\n交易成功\n创建时间  2026-10-24 12:09:18\n付款方式  余额宝  >\n\(tail)\n再转一笔"
        let received = "10:25\n<  账单详情  全部账单\n示例好友\n+1,700.00\n交易成功\n创建时间  2026-10-24 09:44:15\n收款方式  账户余额  >\n\(tail)\n查看往来记录  往来流水证明\n申请电子回单  对此订单有疑问"
        let first = try await backend.ingestScreenshot(text: sent, capturedAt: at(12, 10))
        XCTAssertEqual(first.recordedCount, 1, first.summary)
        let second = try await backend.ingestScreenshot(text: received, capturedAt: at(12, 11))
        XCTAssertEqual(second.recordedCount, 1, second.summary)
        let rows = try await backend.records(accountID: alipay.id).map(\.record)
        XCTAssertEqual(rows.count, 2)
        let out = try XCTUnwrap(rows.first { $0.amountMinor == 51_00 })
        XCTAssertEqual(out.direction, .outflow)
        XCTAssertEqual(out.transactionTime?.sortKey, "2026-10-24T12:09:18")
        let into = try XCTUnwrap(rows.first { $0.amountMinor == 1_700_00 })
        XCTAssertEqual(into.direction, .inflow)
        XCTAssertEqual(into.transactionTime?.sortKey, "2026-10-24T09:44:15")
    }

    // MARK: 同一笔只记一次

    func testSameScreenshotTwiceIsOneRecord() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: at(15, 0))
        let again = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: at(15, 5))
        XCTAssertEqual(again.mergedCount, 1)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testSuccessPageThenDetailPageIsOneRecord() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        let detail = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: at(15, 0))
        XCTAssertEqual(detail.mergedCount, 1, detail.summary)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.transactionTime?.sortKey, "2026-10-24T14:30:45", "补上详情页的时间")
    }

    func testTwoSuccessPagesFarApartAreTwoPayments() async throws {
        let backend = try makeBackend()
        try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        let second = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 38))
        XCTAssertEqual(second.recordedCount, 1, "隔了几分钟、同样金额的两次付款")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    func testBankFirstThenScreenshotFillsTheMerchant() async throws {
        let backend = try makeBackend()
        let card = try await addCard(backend)
        try await addWechat(backend)
        _ = try await backend.ingest(IngestRequest(
            text: "【招商银行】您尾号0427的储蓄卡于10月24日14:30在财付通-示例面馆快捷支付人民币26.00元", source: .auto, receivedAt: at(14, 30, 50)
        ))
        let shot = try await backend.ingestScreenshot(text: wechatCardDetail, capturedAt: at(15, 0))
        XCTAssertEqual(shot.mergedCount, 1, shot.summary)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.accountID, card.id)
        XCTAssertEqual(rows[0].record.counterparty, "示例面馆", "截图上的商户比「财付通-…」准")
        XCTAssertEqual(rows[0].record.source, .auto)
    }

    func testSuccessPageWithoutMethodMergesIntoTheBankRecord() async throws {
        let backend = try makeBackend()
        let card = try await addCard(backend)
        try await addWechat(backend)
        _ = try await backend.ingest(IngestRequest(
            text: "【招商银行】您尾号0427的储蓄卡于10月24日14:30在财付通快捷支付人民币12.00元", source: .auto, receivedAt: at(14, 30, 20)
        ))
        let shot = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        XCTAssertEqual(shot.mergedCount, 1, "成功页没写用什么付的：同金额的银行那笔就是它")
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.accountID, card.id)
        XCTAssertEqual(rows[0].record.counterparty, "示例便利店")
    }

    func testBankArrivingAfterAGuessedWalletMovesTheRecordToTheCard() async throws {
        let backend = try makeBackend()
        let card = try await addCard(backend)
        let wallet = try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        let first = try await backend.records(accountID: wallet.id)
        XCTAssertEqual(first.count, 1, "先记到猜的零钱")
        let bank = try await backend.ingest(IngestRequest(
            text: "【招商银行】您尾号0427的储蓄卡于10月24日14:30在财付通快捷支付人民币12.00元", source: .auto, receivedAt: at(14, 31, 10)
        ))
        XCTAssertEqual(bank.mergedCount, 1, bank.summary)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.accountID, card.id, "银行通知来了：改到这张卡上")
        XCTAssertEqual(rows[0].record.counterparty, "示例便利店")
    }

    func testBankNoticeDoesNotMoveAStatedWalletPayment() async throws {
        let backend = try makeBackend()
        let card = try await addCard(backend)
        let wallet = try await addWechat(backend)
        _ = try await backend.ingestScreenshot(text: wechatDetail, capturedAt: at(15, 0))
        _ = try await backend.ingest(IngestRequest(
            text: "【招商银行】您尾号0427的储蓄卡于10月24日14:31在财付通快捷支付人民币12.00元", source: .auto, receivedAt: at(14, 31, 10)
        ))
        let walletCount = try await backend.recordCount(accountID: wallet.id)
        let cardCount = try await backend.recordCount(accountID: card.id)
        XCTAssertEqual(walletCount, 1, "页面写明了零钱：银行那笔是另一笔")
        XCTAssertEqual(cardCount, 1)
    }

    func testManualRecordStillAsks() async throws {
        let backend = try makeBackend()
        let wallet = try await addWechat(backend)
        try await backend.addRecord(ManualEntry(type: .expense, accountID: wallet.id, amountMinor: 12_00, currency: .cny, time: at(14, 20)))
        let shot = try await backend.ingestScreenshot(text: wechatSuccess, capturedAt: at(14, 31))
        XCTAssertEqual(shot.pendingCount, 1)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .possibleDuplicate)
    }

    // MARK: 银行 App 的换汇页

    /// 众安 App「货币兑换成功」页（照真机截图排成行，交易编号太长换了行）
    let zaExchange = """
    23:33  78
    X  全部动态
    USD 兑换 HKD  +HKD 39.02
    今天 23:31  -USD 5.00
    货币兑换成功
    今天 23:31
    USD 兑换为 HKD
    5.00  39.02
    卖出 (USD)  买入 (HKD)
    兑换汇率  1HKD = 0.128137USD
    交易编号  2026263317600031287091
    2
    时间  11 月 7 日 23:31
    外汇  活期存款
    """

    var afterExchange: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))! }

    @discardableResult
    func addZA(_ backend: LedgerBackend, extra: [CurrencyCode] = [.usd]) async throws -> Account {
        try await backend.addAccount(AccountDraft(
            name: "", bankID: "zabank", bankName: "众安银行", last4: "0106", cardType: .debit, currency: .hkd, paletteID: "ocean", extraCurrencies: extra
        ))
    }

    func testExchangeLegsAreRead() {
        let rows = ScreenshotParser.cleaned(zaExchange).split(separator: "\n").map(String.init)
        let legs = ScreenshotParser.exchangeLegs(rows: rows, cleaned: ScreenshotParser.cleaned(zaExchange))
        XCTAssertEqual(legs?.sold, ScreenshotParser.ExchangeLeg(currency: .usd, digits: "5.00"))
        XCTAssertEqual(legs?.bought, ScreenshotParser.ExchangeLeg(currency: .hkd, digits: "39.02"))
        // 只截到上半页：看带正负号的金额
        let header = "USD 兑换 HKD  +HKD 39.02\n今天 23:31  -USD 5.00\n货币兑换成功"
        let fromHeader = ScreenshotParser.exchangeLegs(rows: header.split(separator: "\n").map(String.init), cleaned: header)
        XCTAssertEqual(fromHeader?.sold, ScreenshotParser.ExchangeLeg(currency: .usd, digits: "5.00"))
        XCTAssertEqual(fromHeader?.bought, ScreenshotParser.ExchangeLeg(currency: .hkd, digits: "39.02"))
        XCTAssertNil(ScreenshotParser.exchangeLegs(rows: wechatDetail.split(separator: "\n").map(String.init), cleaned: wechatDetail))
    }

    func testBankExchangePageIsRecordedAsAnExchangeOnTheSameAccount() async throws {
        let backend = try makeBackend()
        let za = try await addZA(backend)
        let result = try await backend.ingestScreenshot(text: zaExchange, capturedAt: afterExchange)
        XCTAssertEqual(result.recordedCount, 2, result.summary)
        let rows = try await backend.records(accountID: za.id).map(\.record)
        XCTAssertEqual(rows.count, 2)
        let sold = try XCTUnwrap(rows.first { $0.direction == .outflow })
        let bought = try XCTUnwrap(rows.first { $0.direction == .inflow })
        XCTAssertEqual(sold.currency, .usd)
        XCTAssertEqual(sold.amountMinor, 5_00)
        XCTAssertEqual(sold.kind, .transferOut)
        XCTAssertEqual(bought.currency, .hkd)
        XCTAssertEqual(bought.amountMinor, 39_02)
        XCTAssertEqual(bought.kind, .transferIn)
        XCTAssertNotNil(sold.transferGroupID)
        XCTAssertEqual(sold.transferGroupID, bought.transferGroupID, "卖出、买入配成同卡换汇")
        XCTAssertEqual(sold.bankReference, "20262633176000312870912", "换行的交易编号接上")
        XCTAssertEqual(sold.transactionTime?.month, 11)
        XCTAssertEqual(sold.transactionTime?.day, 7)
        XCTAssertEqual(sold.transactionTime?.hour, 23)
        XCTAssertEqual(sold.transactionTime?.minute, 31)
        XCTAssertEqual(sold.transactionTime?.year, 2026)
    }

    func testSameExchangeScreenshotTwiceIsOneExchange() async throws {
        let backend = try makeBackend()
        try await addZA(backend)
        _ = try await backend.ingestScreenshot(text: zaExchange, capturedAt: afterExchange)
        let again = try await backend.ingestScreenshot(text: zaExchange, capturedAt: afterExchange.addingTimeInterval(600))
        XCTAssertEqual(again.mergedCount, 2, again.summary)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    func testExchangeWithoutAnAccountHoldingBothCurrenciesAsks() async throws {
        let backend = try makeBackend()
        let za = try await addZA(backend, extra: [.cny])
        let result = try await backend.ingestScreenshot(text: zaExchange, capturedAt: afterExchange)
        XCTAssertEqual(result.pendingCount, 2, result.summary)
        let items = try await backend.openPendingItems()
        XCTAssertTrue(items.allSatisfy { $0.reason == .ambiguousAccount })
        XCTAssertEqual(items.first?.candidateAccountIDs, [za.id])
    }
}
