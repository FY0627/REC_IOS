import Foundation
import XCTest
@testable import BKBackend
import BKModel

/// 解析样例。所有样例都是按银行通知的公开常见写法构造的脱敏文本：
/// 卡号尾号、金额、商户、时间均为虚构，不来自真实用户数据。
final class ParserSampleTests: XCTestCase {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    static let reference = Date(timeIntervalSince1970: 1_792_828_800) // 2026-10-24 16:00 +08:00

    func parse(_ text: String, source: SourceKind = .sms, sender: String? = nil, subject: String? = nil) -> ParsedMessage {
        MessageParser.parse(MessageContext(text: text, source: source, sender: sender, subject: subject, referenceDate: Self.reference, calendar: Self.calendar))
    }

    func single(_ text: String, source: SourceKind = .sms, sender: String? = nil, subject: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> EventDraft? {
        let parsed = parse(text, source: source, sender: sender, subject: subject)
        XCTAssertEqual(parsed.classification, .transaction, "classification", file: file, line: line)
        XCTAssertEqual(parsed.events.count, 1, "event count: \(parsed.events.map(\.draft.amount.digits))", file: file, line: line)
        XCTAssertNil(parsed.events.first?.issue, "issue", file: file, line: line)
        return parsed.events.first?.draft
    }

    // MARK: 消费

    func testPurchaseWithMerchantTimeAndBalance() throws {
        let d = try XCTUnwrap(single("【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元，余额1,234.56元。", sender: "95555"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.amount.digits, "38.00")
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.counterparty, "星巴克咖啡")
        XCTAssertEqual(d.balanceAfter?.digits, "1,234.56")
        XCTAssertEqual(d.transactionTime, WallClock(year: 2026, month: 10, day: 24, hour: 14, minute: 30, yearInferred: true))
        XCTAssertEqual(d.bankHint, "cmb")
    }

    func testCreditCardPurchaseWithoutMerchant() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月23日21:05消费1,280.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertNil(d.counterparty, "商户缺失时不编造")
        XCTAssertEqual(d.bankHint, "boc")
    }

    func testQuickPaymentWithSummaryMerchant() throws {
        let d = try XCTUnwrap(single("您账户6621于10月24日09:12快捷支付支出人民币56.80元，摘要：美团外卖，余额2,003.20元【工商银行】"))
        XCTAssertEqual(d.cardTail, "6621")
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.counterparty, "美团外卖")
    }

    func testEnglishCardPurchaseInEuro() throws {
        let d = try XCTUnwrap(single("Your card ending 3305 was charged EUR 12,50 at REWE MARKT on 24.10.2026 13:02. Available balance: EUR 1.204,30."))
        XCTAssertEqual(d.cardTail, "3305")
        XCTAssertEqual(d.amount.digits, "12,50")
        XCTAssertEqual(d.amount.currencyCandidates, [.eur])
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.counterparty, "REWE MARKT")
        XCTAssertEqual(d.balanceAfter?.digits, "1.204,30")
        XCTAssertEqual(d.transactionTime?.isMinutePrecise, true)
        XCTAssertEqual(d.transactionTime?.day, 24)
    }

    // MARK: 入账

    func testSalaryIncome() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月15日09:30收入人民币12,500.00元，摘要：代发工资，余额13,734.56元【招商银行】"))
        XCTAssertEqual(d.kind, .salary)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertNil(d.counterparty, "「代发工资」是交易性质，不是交易对方")
    }

    func testTransferInFromPerson() throws {
        let d = try XCTUnwrap(single("张三于10月24日10:01向您尾号0427的账户转账500.00元，余额1,734.56元。【招商银行】"))
        XCTAssertEqual(d.kind, .transferIn)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.counterparty, "张三")
    }

    func testTransferOutWithSeparateFee() throws {
        let parsed = parse("您尾号6621卡10月24日11:20跨行转出1,000.00元，手续费2.00元，余额998.00元。【工商银行】")
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertEqual(parsed.events.count, 2)
        let main = parsed.events[0].draft
        let fee = parsed.events[1].draft
        XCTAssertEqual(main.kind, .transferOut)
        XCTAssertEqual(main.amount.digits, "1,000.00")
        XCTAssertNil(main.includedFee)
        XCTAssertEqual(fee.kind, .fee)
        XCTAssertEqual(fee.amount.digits, "2.00")
        XCTAssertFalse(fee.isSplitFee)
        XCTAssertEqual(fee.cardTail, "6621")
        XCTAssertEqual(main.balanceAfter?.digits, "998.00")
    }

    func testFeeIncludedInTotalIsSplitNotDoubleCounted() throws {
        let parsed = parse("您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】")
        XCTAssertEqual(parsed.events.count, 2)
        let main = parsed.events[0].draft
        XCTAssertEqual(main.amount.digits, "1,002.00")
        XCTAssertEqual(main.includedFee?.digits, "2.00")
        XCTAssertEqual(parsed.events[1].draft.kind, .fee)
        XCTAssertTrue(parsed.events[1].draft.isSplitFee)
    }

    func testRefund() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡收到退款人民币99.00元，商户：京东商城。【中国银行】"))
        XCTAssertEqual(d.kind, .refund)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.counterparty, "京东商城")
    }

    func testCreditCardRepaymentReceived() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡于10月20日还款成功，金额3,000.00元已入账。【中国银行】"))
        XCTAssertEqual(d.kind, .repayment)
        XCTAssertEqual(d.direction, .inflow)
    }

    func testDebitRepaymentDirectionResolvedLater() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月20日10:00还款3,000.00元，余额734.56元【招商银行】"))
        XCTAssertEqual(d.kind, .repayment)
        XCTAssertNil(d.direction, "方向由账户类型决定")
    }

    func testLoanInterestCharge() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月21日扣收贷款利息人民币86.40元，余额648.16元。【招商银行】"))
        XCTAssertEqual(d.kind, .interestCharge)
        XCTAssertEqual(d.direction, .outflow)
    }

    func testInterestIncome() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月21日结息入账3.27元，余额737.83元。【招商银行】"))
        XCTAssertEqual(d.kind, .interestIncome)
        XCTAssertEqual(d.direction, .inflow)
    }

    func testStandaloneAnnualFee() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月22日扣收年费200.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .fee)
        XCTAssertEqual(d.amount.digits, "200.00")
    }

    func testCashDepositAndWithdrawal() throws {
        let deposit = try XCTUnwrap(single("您尾号0427账户10月22日现金存入2,000.00元，余额2,737.83元【招商银行】"))
        XCTAssertEqual(deposit.kind, .deposit)
        XCTAssertEqual(deposit.direction, .inflow)
        let withdrawal = try XCTUnwrap(single("您尾号0427账户10月22日ATM取款500.00元，余额2,237.83元【招商银行】"))
        XCTAssertEqual(withdrawal.kind, .withdrawal)
        XCTAssertEqual(withdrawal.direction, .outflow)
    }

    func testReversalOfPurchase() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月23日消费撤销人民币1,280.00元。【中国银行】"))
        XCTAssertEqual(d.kind, .reversal)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.status, .posted)
    }

    func testGenericDebitWithoutKindIsOther() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月22日支出人民币300.00元，余额1,937.83元【招商银行】"))
        XCTAssertEqual(d.kind, .other)
        XCTAssertEqual(d.direction, .outflow)
    }

    // MARK: 状态：失败、预授权、冻结

    func testFailedPayment() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日在苹果商店消费68.00元交易失败，原因：余额不足。【中国银行】"))
        XCTAssertEqual(d.status, .failed)
    }

    func testPreAuthorizationIsHold() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日在某某酒店预授权人民币2,000.00元。【中国银行】"))
        XCTAssertEqual(d.status, .hold)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testPreAuthorizationCompletionIsPosted() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月26日在某某酒店预授权完成人民币1,650.00元。【中国银行】"))
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testPreAuthorizationReleased() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月26日预授权撤销人民币2,000.00元。【中国银行】"))
        XCTAssertEqual(d.status, .holdReleased)
        XCTAssertEqual(d.direction, .inflow)
    }

    // MARK: 非交易信息

    func testVerificationCodeIsFiltered() {
        let parsed = parse("【招商银行】您正在进行网上支付，金额100.00元，验证码：482913，请勿泄露。")
        XCTAssertEqual(parsed.classification, .verificationCode)
        XCTAssertTrue(parsed.events.isEmpty)
    }

    func testSecurityWarningMentioningCodeIsNotOTP() throws {
        let d = try XCTUnwrap(single("您尾号0427的储蓄卡10月24日15:10消费人民币20.00元，余额1,214.56元。银行不会索要验证码。【招商银行】"))
        XCTAssertEqual(d.amount.digits, "20.00")
    }

    func testMarketingIsFiltered() {
        XCTAssertEqual(parse("【某银行】尊敬的客户，信用卡分期优惠来袭，最高可借50,000元，详询客服，回T退订").classification, .marketing)
    }

    func testRepaymentReminderIsNotATransaction() {
        XCTAssertEqual(parse("【中国银行】您尾号8810的信用卡本期账单应还款额3,000.00元，最低还款300.00元，到期还款日11月05日，请按时还款。").classification, .reminder)
        XCTAssertEqual(parse("您尾号8810的信用卡将于10月25日自动扣款3,000.00元，请确保账户资金充足。【中国银行】").classification, .reminder)
    }

    func testStatementEmailIsNotReparsed() {
        let parsed = parse("<html><body><p>尊敬的客户：</p><table><tr><td>10/03</td><td>星巴克</td><td>38.00</td></tr></table></body></html>", source: .email, subject: "中国银行信用卡电子账单")
        XCTAssertEqual(parsed.classification, .statement)
    }

    func testBalanceOnlyNeverInventsTransaction() {
        let parsed = parse("您尾号0427账户截至10月24日16:00的可用余额为1,234.56元。【招商银行】")
        XCTAssertEqual(parsed.classification, .balanceSnapshot)
        XCTAssertTrue(parsed.events.isEmpty)
        XCTAssertEqual(parsed.balances.first?.amount.digits, "1,234.56")
        XCTAssertEqual(parsed.balances.first?.cardTail, "0427")
    }

    func testCreditLimitChangeIsNotMoneyMovement() {
        XCTAssertEqual(parse("您尾号8810的信用卡固定额度已调整为50,000元，即日生效。【中国银行】").classification, .creditLimitChange)
    }

    func testUnrecognizedGoesToPending() {
        // 有尾号但没有可识别的交易：可能是新格式，进入待处理
        XCTAssertEqual(parse("【某银行】您尾号0427的账户信息已更新。").classification, .unrecognized)
        // 没有金额也没有尾号：不是动账通知（例如按关键词误触发的聊天短信）
        XCTAssertEqual(parse("【某银行】您的账户信息已更新。").classification, .noFinancialContent)
        XCTAssertEqual(parse("明天下午我要去银行办点事").classification, .noFinancialContent)
    }

    // MARK: 金额歧义、币种

    func testMultipleTransactionAmountsInOneSentenceAreAmbiguous() {
        let parsed = parse("您尾号0427账户10月24日消费100.00元实际扣款95.00元【招商银行】")
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertTrue(parsed.events.allSatisfy { $0.issue == .ambiguousAmount })
    }

    func testYenSymbolInChineseTextPrefersCNY() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日消费¥45.00【招商银行】"))
        XCTAssertEqual(d.amount.currencyCandidates, [.cny, .jpy])
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
    }

    func testForeignCurrencyCode() throws {
        let d = try XCTUnwrap(single("您尾号8810的信用卡10月24日消费USD 25.99，商户：AMAZON。【中国银行】"))
        XCTAssertEqual(d.amount.currencyCandidates, [.usd])
        XCTAssertEqual(d.counterparty, "AMAZON")
    }

    func testAmountWithoutCurrencyHasNoCandidates() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日消费45.00，余额1,000.00【招商银行】"))
        XCTAssertTrue(d.amount.currencyCandidates.isEmpty, "交给账户币种决定，不按设备地区猜")
    }

    // MARK: 邮件

    func testEmailHTMLIgnoresQuotedHistory() throws {
        let html = """
        <html><body><div>尊敬的客户：</div><div>您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40，余额EUR 1,180.90。</div>
        <blockquote><div>您尾号3305的借记卡于2026-10-20 08:00在BAECKEREI消费EUR 3.20。</div></blockquote></body></html>
        """
        let d = try XCTUnwrap(single(html, source: .email, sender: "notice@example-bank.eu", subject: "交易提醒"))
        XCTAssertEqual(d.amount.digits, "23.40")
        XCTAssertEqual(d.counterparty, "DM DROGERIE")
        XCTAssertEqual(d.transactionTime, WallClock(year: 2026, month: 10, day: 24, hour: 12, minute: 40))
    }

    func testEmailReplyHistoryIsStripped() throws {
        let text = """
        您尾号3305的借记卡于2026-10-24 12:40消费EUR 23.40。
        -----Original Message-----
        您尾号3305的借记卡于2026-10-20 08:00消费EUR 3.20。
        """
        let d = try XCTUnwrap(single(text, source: .email))
        XCTAssertEqual(d.amount.digits, "23.40")
    }

    func testEmailWithMultipleTransactions() {
        let text = """
        交易提醒
        您尾号3305的借记卡于2026-10-24 09:10在BAECKEREI消费EUR 3.20。
        您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40。
        您尾号3305的借记卡于2026-10-24 12:40在DM DROGERIE消费EUR 23.40。
        """
        let parsed = parse(text, source: .email)
        XCTAssertEqual(parsed.classification, .transaction)
        XCTAssertEqual(parsed.events.map(\.draft.amount.digits), ["3.20", "23.40"], "重复行只保留一次，不只取第一笔")
        XCTAssertEqual(parsed.events.map(\.draft.partIndex), [0, 2])
    }

    func testForwardedBankEmailUsesForwardedBody() throws {
        let text = """
        ---------- Forwarded message ----------
        From: notice@example-bank.eu
        Date: 24.10.2026
        Subject: 交易提醒
        您尾号3305的借记卡于2026-10-24 12:40消费EUR 23.40。
        """
        let d = try XCTUnwrap(single(text, source: .email))
        XCTAssertEqual(d.amount.digits, "23.40")
    }

    // MARK: 尾号与日期

    func testCardTailFormats() {
        XCTAssertEqual(parse("卡号**0042于10月24日消费30.00元").events.first?.draft.cardTail, "0042")
        XCTAssertEqual(parse("Card *9912 debited EUR 5.00 on 24 Oct 2026").events.first?.draft.cardTail, "9912")
        XCTAssertEqual(parse("您的借记卡账户0007于10月24日支出100.00元").events.first?.draft.cardTail, "0007")
    }

    func testTwoTailsMarkCounterpartyAccount() throws {
        let d = try XCTUnwrap(single("您尾号0427账户10月24日向尾号6621账户转账200.00元，余额500.00元【招商银行】"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.counterpartyTail, "6621")
        XCTAssertEqual(d.kind, .transferOut)
    }

    func testYearInferenceAcrossNewYear() {
        // 1 月 2 日收到「12月31日」的通知 → 上一年
        var calendar = Self.calendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ref = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9))!
        let parsed = MessageParser.parse(MessageContext(text: "您尾号0427账户12月31日23:50消费10.00元", source: .sms, sender: nil, subject: nil, referenceDate: ref, calendar: calendar))
        XCTAssertEqual(parsed.events.first?.draft.transactionTime?.year, 2026)
    }

    func testAmbiguousSlashDateKeepsNoDate() {
        let parsed = parse("Card ending 3305 debited EUR 5.00 on 03/04/2026 10:00")
        let time = parsed.events.first?.draft.transactionTime
        XCTAssertNil(time?.month, "03/04 无法区分日/月时不写日期")
        XCTAssertEqual(time?.hour, 10)
    }

    func testFullWidthDigitsAndPunctuation() throws {
        let d = try XCTUnwrap(single("您尾号０４２７账户１０月２４日消费人民币３８．００元【招商银行】"))
        XCTAssertEqual(d.cardTail, "0427")
        XCTAssertEqual(d.amount.digits, "38.00")
    }

    // MARK: 收入写明了就是收入

    func testIncomeThroughOnlinePaymentIsInflow() throws {
        let d = try XCTUnwrap(single(Self.bocIncome))
        XCTAssertEqual(d.cardTail, "0001")
        XCTAssertEqual(d.amount.digits, "88.00")
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
        XCTAssertEqual(d.direction, .inflow)
        XCTAssertEqual(d.kind, .other, "写了收入但没说是什么收入，和只写「收入」一样")
        XCTAssertEqual(d.balanceAfter?.digits, "188.00")
    }

    func testIncomeWithPaymentChannelElsewhereIsInflow() throws {
        let bracket = try XCTUnwrap(single("您的借记卡账户0001，于10月31日手机银行收入(跨行支付)人民币100.00元,交易后余额188.00【中国银行】"))
        XCTAssertEqual(bracket.direction, .inflow)
        let summary = try XCTUnwrap(single("您尾号0001账户10月31日收入人民币50.00元，摘要：网上支付【招商银行】"))
        XCTAssertEqual(summary.direction, .inflow)
    }

    func testCrossBankPaymentStaysOutflow() throws {
        let d = try XCTUnwrap(single("您的借记卡账户0001，于10月31日手机银行支取(跨行支付)人民币100.00元,交易后余额88.00【中国银行】"))
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testPostedCardPurchaseIsNotIncome() throws {
        let d = try XCTUnwrap(single("您尾号0001的信用卡10月31日消费入账人民币30.00元【招商银行】"))
        XCTAssertEqual(d.direction, .outflow, "「入账」说的是这笔已记账，不是钱进来了")
    }

    // MARK: 招行预授权和完成扣款

    func testCompletedCaptureIsPostedWithMerchant() throws {
        let d = try XCTUnwrap(single(Self.cmbCapture))
        XCTAssertEqual(d.status, .posted, "括号里的「交易预授权时间」不决定状态")
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.cardTail, "0002")
        XCTAssertEqual(d.amount.digits, "48.00")
        XCTAssertEqual(d.amount.preferredCurrency, .cny)
        XCTAssertEqual(d.counterparty, #"EXAMPLE.COM/JP\TEST BUILDING NAME\TOKYO\100-00"#)
        XCTAssertEqual(d.transactionTime?.day, 31)
        XCTAssertEqual(d.holdTime?.month, 10)
        XCTAssertEqual(d.holdTime?.day, 30)
        XCTAssertEqual(d.holdTime?.hour, 10)
        XCTAssertEqual(d.holdTime?.minute, 20)
    }

    func testTimeNoteDoesNotDecideStatus() throws {
        let d = try XCTUnwrap(single("您尾号0002账户10月31日10:20消费人民币48.00（交易预授权时间10月30日10:20）【招商银行】"))
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.kind, .purchase)
    }

    func testHoldWithBracketedChargeIsOneEvent() throws {
        let d = try XCTUnwrap(single(Self.cmbHold))
        XCTAssertEqual(d.status, .hold)
        XCTAssertEqual(d.kind, .purchase)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.cardTail, "0002")
        XCTAssertEqual(d.amount.digits, "1000.00")
        XCTAssertEqual(d.amount.currencyCandidates, [.jpy])
        XCTAssertEqual(d.settlement?.digits, "48.00")
        XCTAssertEqual(d.settlement?.preferredCurrency, .cny)
        XCTAssertEqual(d.counterparty, "EXAMPLE.COM/JP TOKYO JPN")
        XCTAssertNil(d.holdTime, "冻结本身没有「之前的预授权」")
    }

    func testPurchaseWithBracketedChargeIsOneEvent() throws {
        let d = try XCTUnwrap(single("您尾号0002账户10月31日10:20消费JPY1000.00（人民币48.00），余额100.00元【招商银行】"))
        XCTAssertEqual(d.status, .posted)
        XCTAssertEqual(d.amount.currencyCandidates, [.jpy])
        XCTAssertEqual(d.settlement?.digits, "48.00")
        XCTAssertEqual(d.balanceAfter?.digits, "100.00")
    }

    func testOtherTwoAmountWordingsStayAmbiguous() {
        for text in [
            "您尾号0002账户10月24日消费100.00元实际扣款95.00元【招商银行】",
            "您尾号0002账户10月24日消费人民币100.00（人民币95.00）【招商银行】",
            "您尾号0002账户10月24日消费JPY1000.00，另消费人民币48.00【招商银行】",
        ] {
            let parsed = parse(text)
            XCTAssertEqual(parsed.events.count, 2, text)
            XCTAssertTrue(parsed.events.allSatisfy { $0.issue == .ambiguousAmount && $0.draft.settlement == nil }, text)
        }
    }

    func testSameAmountTwiceIsOneEventOnlyWhenItRestatesAHold() throws {
        let hold = try XCTUnwrap(single("您的借记卡0001于0618发生无卡消费交易，金额8.00美元，已冻结8.00美元。【中国银行】"))
        XCTAssertEqual(hold.status, .hold)
        let parsed = parse("您尾号0001账户10月24日消费100.00元，退款100.00元【招商银行】")
        XCTAssertEqual(parsed.events.count, 2)
        XCTAssertTrue(parsed.events.allSatisfy { $0.issue == .ambiguousAmount })
    }

    // MARK: 汇款方向、紧凑日期、币种代码

    func testRemittanceResultDecidesDirection() throws {
        let out = try XCTUnwrap(single("您账户0001于20260928的汇款 (100.00人民币) 已汇出，需收款人关注到账情况【招商银行】"))
        XCTAssertEqual(out.kind, .transferOut)
        XCTAssertEqual(out.direction, .outflow)
        // 没写结果也没写方向：还是不猜
        let parsed = parse("您账户0001汇款100.00元，收款人张三【招商银行】")
        XCTAssertEqual(parsed.events.first?.issue, .uncertainKind)
    }

    func testCompactDates() throws {
        let short = try XCTUnwrap(single("您的借记卡0001于0618发生无卡消费交易，金额8.00美元。【中国银行】"))
        XCTAssertEqual(short.transactionTime?.month, 6)
        XCTAssertEqual(short.transactionTime?.day, 18)
        let full = try XCTUnwrap(single("您账户0001于20260928的汇款 (100.00人民币) 已汇出【招商银行】"))
        XCTAssertEqual(full.transactionTime?.year, 2026)
        XCTAssertEqual(full.transactionTime?.month, 9)
        XCTAssertEqual(full.transactionTime?.day, 28)
    }

    func testEveryISOCodeIsACurrencyButOnlyInCapitals() throws {
        let d = try XCTUnwrap(single("您尾号0001账户10月24日消费THB120.50【招商银行】"))
        XCTAssertEqual(d.amount.currencyCandidates, [CurrencyCode("THB")])
        XCTAssertEqual(CurrencyTokens.suffix(in: " PHP")?.candidates, [CurrencyCode("PHP")])
        XCTAssertNil(CurrencyTokens.prefix(in: "top "), "「top 10」不是金额")
        XCTAssertNil(CurrencyTokens.prefix(in: "SHOP "), "单词的一部分不算")
    }

    func testDraftSavedByOlderVersionStillDecodes() throws {
        let draft = try XCTUnwrap(single(Self.cmbHold))
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        XCTAssertNotNil(saved["settlement"])
        saved["settlement"] = nil
        saved["holdTime"] = nil
        let decoded = try JSONDecoder().decode(EventDraft.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(decoded.settlement)
        XCTAssertNil(decoded.holdTime)
        XCTAssertEqual(decoded.amount, draft.amount)
    }

    static let bocIncome = "您的借记卡账户0001，于10月31日网上支付收入人民币88.00元,交易后余额188.00【中国银行】"
    static let cmbHold = "【招商银行】您绑定在Apple Pay上的账户0002（设备卡号0099）于10月30日10:20在EXAMPLE.COM/JP           TOKYO         JPN预授权冻结JPY1000.00（人民币48.00），请留意后续扣款通知"
    static let cmbCapture = #"【招商银行】您绑定在Apple Pay上的账户0002（设备卡号0099）于10月31日10:20在EXAMPLE.COM/JP\TEST BUILDING NAME\TOKYO\100-00完成扣款人民币48.00（交易预授权时间10月30日10:20）"#

    // MARK: 电话号码和打码的号码

    func testMaskedPhoneIsNotACardTail() {
        XCTAssertEqual(parse("尊敬的（138****0011）客户，您好！").cardTails, [])
        XCTAssertEqual(parse("快递员电话138 **** 0012，请保持电话畅通").cardTails, [])
        XCTAssertEqual(parse("收款人手机+86-13800**0011").cardTails, [])
    }

    func testMaskedCardNumberIsStillACardTail() {
        XCTAssertEqual(parse("您的卡6222****1234于10月24日消费30.00元").events.first?.draft.cardTail, "1234")
        XCTAssertEqual(parse("您的卡1380****1234于10月24日消费30.00元").events.first?.draft.cardTail, "1234", "12 位不是手机号")
    }

    /// 众安银行转账到手机号（脱敏）：手机号、区号、客服电话里的数字都不是金额
    static let phoneTransfer = #"【众安银行】ZA Bank:你已于 2026-03-19 20:05:31 将 HKD 23.75 转出至"+86-138******00"。交易类型：手机号转出。如你无递交以上指示，可致电 +852 3665 3665。"#

    func testPhoneNumbersAreNotAmounts() throws {
        let d = try XCTUnwrap(single(Self.phoneTransfer))
        XCTAssertEqual(d.amount.digits, "23.75")
        XCTAssertEqual(d.amount.currencyCandidates, [.hkd])
        XCTAssertEqual(d.kind, .transferOut)
        XCTAssertEqual(d.direction, .outflow)
        XCTAssertEqual(d.counterparty, "+86-138******00")
        XCTAssertNil(d.cardTail)
        XCTAssertEqual(d.transactionTime, WallClock(year: 2026, month: 3, day: 19, hour: 20, minute: 5, second: 31))
    }
}
