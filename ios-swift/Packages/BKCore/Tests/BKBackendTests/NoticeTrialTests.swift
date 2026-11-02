import Foundation
import XCTest
@testable import BKBackend
import BKModel

final class NoticeTrialTests: XCTestCase {
    func rules(_ text: String) -> NoticeReading {
        NoticeReading(rules: text, referenceDate: ParserSampleTests.reference, calendar: ParserSampleTests.calendar)
    }

    func row(_ sample: NoticeSamples.Sample, model: NoticeReading?, failure: String? = nil, seconds: Double = 1) -> NoticeTrialRow {
        NoticeTrialRow(id: 1, sample: sample, rules: rules(sample.text), model: model, failure: failure, seconds: seconds)
    }

    /// 试读页面里规则这一列要和入账测试一致，否则比出来的差别不是模型的问题
    func testRulesReadEverySample() {
        var wrong: [String] = []
        for (index, sample) in NoticeSamples.all.enumerated() {
            for difference in NoticeComparison.differences(answer: sample.answer, reading: rules(sample.text)) {
                wrong.append("#\(index + 1) \(difference.field.rawValue) 应为 \(difference.expected)，读成 \(difference.actual)")
            }
        }
        XCTAssertEqual(wrong, [])
    }

    func testAnswerComesFromExpected() {
        let hold = NoticeSamples.Sample(text: "您账户0002预授权冻结JPY900.00", expected: "入账 0002 -900 JPY purchase hold @EXAMPLE SHOP TOKYO JPN 实扣38.37")
        XCTAssertEqual(hold.answer, NoticeReading(
            isTransaction: true, amount: "900", currency: "JPY", direction: .outflow, kind: .purchase, status: .hold,
            cardTail: "0002", counterparty: "EXAMPLE SHOP TOKYO JPN"
        ))
        let noTail = NoticeSamples.Sample(text: "你已转出 CNY 365.03", expected: "入账 0003 -365.03 CNY transferOut posted")
        XCTAssertNil(noTail.answer.cardTail, "通知没写的尾号不算")
        XCTAssertFalse(NoticeSamples.Sample(text: "验证码", expected: "忽略").answer.isTransaction)
    }

    func testComparisonIgnoresTheWayItIsWritten() {
        let answer = NoticeReading(isTransaction: true, amount: "2.00", currency: "CNY", direction: .outflow, kind: .purchase, status: .posted, cardTail: "0004", counterparty: "WEIXIN*test shop Shenzhen CN")
        let reading = NoticeReading(isTransaction: true, amount: "CNY 2", currency: "cny", direction: .outflow, kind: .purchase, status: .posted, cardTail: "004", counterparty: "test shop")
        XCTAssertEqual(NoticeComparison.differences(answer: answer, reading: reading), [])
    }

    func testComparisonReportsWrongFields() {
        let answer = NoticeReading(isTransaction: true, amount: "1,200.00", currency: "HKD", direction: .inflow, kind: .refund, status: .posted, cardTail: "0001", counterparty: "TEST")
        let reading = NoticeReading(isTransaction: true, amount: "120.00", currency: "HKD", direction: .outflow, kind: .refund, status: .posted, cardTail: "0009")
        XCTAssertEqual(NoticeComparison.differences(answer: answer, reading: reading).map(\.field), [.amount, .direction, .cardTail, .counterparty])
    }

    func testNotATransactionIsOnlyComparedOnThat() {
        let answer = NoticeReading(isTransaction: false)
        XCTAssertEqual(NoticeComparison.differences(answer: answer, reading: answer), [])
        let reading = NoticeReading(isTransaction: true, amount: "10.00")
        XCTAssertEqual(NoticeComparison.differences(answer: answer, reading: reading).map(\.field), [.isTransaction])
    }

    /// 「其他」是通知没写性质，读成哪一种都不算错
    func testOtherKindIsNotCompared() {
        let answer = NoticeReading(isTransaction: true, kind: .other)
        XCTAssertNil(NoticeComparison.matches(.kind, answer: answer, reading: NoticeReading(isTransaction: true, kind: .salary)))
    }

    func testInventedAmountAndTail() {
        let text = "【恒生銀行】你在结尾号码0004的卡支付了CNY2，又付了USD0.80和HKD1,234.50。"
        XCTAssertEqual(NoticeReading(isTransaction: true, amount: "2.00", cardTail: "0004").invented(in: text), [])
        XCTAssertEqual(NoticeReading(isTransaction: true, amount: "0.8").invented(in: text), [])
        XCTAssertEqual(NoticeReading(isTransaction: true, amount: "1234.5").invented(in: text), [])
        XCTAssertEqual(NoticeReading(isTransaction: true, amount: "20.00", cardTail: "9999").invented(in: text), [.amount, .cardTail])
        XCTAssertEqual(NoticeReading(isTransaction: true, amount: "4.50").invented(in: text), [.amount], "数字的一部分不算")
    }

    func testScoresLeaveFailedReadsOutOfTheModelColumn() throws {
        let sample = NoticeSamples.all[0]
        let good = row(sample, model: sample.answer)
        var wrong = sample.answer
        wrong.amount = "9.99"
        let scores = NoticeTrial.scores([good, row(sample, model: wrong), row(sample, model: nil, failure: "rateLimited")])
        let amount = try XCTUnwrap(scores.first { $0.field == .amount })
        XCTAssertEqual(amount.rulesTotal, 3)
        XCTAssertEqual(amount.rulesRight, 3)
        XCTAssertEqual(amount.modelTotal, 2)
        XCTAssertEqual(amount.modelRight, 1)
    }

    func testTimingCountsSuccessfulReadsOnly() throws {
        let sample = NoticeSamples.all[0]
        let timing = try XCTUnwrap(NoticeTrial.timing([
            row(sample, model: sample.answer, seconds: 1), row(sample, model: sample.answer, seconds: 3), row(sample, model: nil, failure: "x", seconds: 0.01),
        ]))
        XCTAssertEqual(timing.average, 2)
        XCTAssertEqual(timing.slowest, 3)
        XCTAssertNil(NoticeTrial.timing([row(sample, model: nil, failure: "x")]))
    }

    func testReportNamesEveryProblem() {
        let sample = NoticeSamples.all[0]
        var wrong = sample.answer
        wrong.amount = "9.99"
        let report = NoticeTrial.report([row(sample, model: wrong), row(sample, model: nil, failure: "rateLimited")], header: ["这台手机：可用"])
        XCTAssertTrue(report.hasPrefix("这台手机：可用\n样本 2 条，读取失败 1 条，金额或尾号不在原文里 1 条"), report)
        XCTAssertTrue(report.contains("#1 金额：应为 0.56，读成 9.99"), report)
        XCTAssertTrue(report.contains("#1 读取失败：rateLimited"), report)
        XCTAssertTrue(report.contains("#1 不在原文里：金额"), report)
    }
}
