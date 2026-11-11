import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 用户手机上收到的通知（中行、招行、众安、恒生、建行、Maya），每条走完整的入账流程，核对最后记成了什么。
/// 文字和写法保持原样；尾号、金额、日期、验证码、链接换成了假的，商户和转账对象也是虚构的。
/// 新增样本时同样处理，不要放真实的号码和商户。
final class RealSampleTests: XCTestCase {
    struct Sample {
        var text: String
        /// 见 `describe`：`入账 尾号 ±金额 币种 性质 状态 @商户 实扣金额`、`待处理 原因 …`、`忽略`
        var expected: String
    }

    /// 顺序和发生的先后一致：冻结在完成扣款前面
    static let samples: [Sample] = [
        // 中行
        Sample(text: "您的账户0001，于10月05日手机银行支取英镑0.56镑,交易后余额0.00【中国银行】", expected: "入账 0001 -0.56 GBP other posted"),
        Sample(text: "您的账户0001，于10月05日手机银行收入人民币4.89元,交易后余额56.11【中国银行】", expected: "入账 0001 +4.89 CNY other posted"),
        Sample(text: "您的借记卡账户0001，于10月05日手机银行收入美元7.32元,交易后余额7.32【中国银行】", expected: "入账 0001 +7.32 USD other posted"),
        Sample(text: "您的借记卡账户0001，于10月28日网上支付收入人民币300.00元,交易后余额356.11【中国银行】", expected: "入账 0001 +300.00 CNY other posted"),
        Sample(text: "您的借记卡账户0001，于10月28日手机银行支取(跨行支付)人民币356.11元,交易后余额0.00【中国银行】", expected: "入账 0001 -356.11 CNY purchase posted"),
        Sample(text: "您的借记卡账户0001，于05月29日网上支付收入人民币75.00元,交易后余额75.00【中国银行】", expected: "入账 0001 +75.00 CNY other posted"),
        Sample(text: "您的借记卡账户0001，于05月30日网上支付支取人民币12.64元,交易后余额62.36【中国银行】", expected: "入账 0001 -12.64 CNY purchase posted"),
        Sample(text: "SMS verify code123456，you are using Debit card0006 for trading online on2026/06/18(YMD),amount isUSD8.00【Bank Of China】", expected: "忽略"),
        Sample(text: "您的借记卡0006于0618发生双信息无卡消费交易，金额8.00美元，已冻结8.00美元。【中国银行】", expected: "入账 0006 -8.00 USD purchase hold"),

        // 招行
        Sample(text: "【招商银行】您绑定在Apple Pay上的账户0002（设备卡号0099）于10月20日15:45在EXAMPLE.COM/JP TOKYO JPN预授权冻结JPY900.00（人民币38.37），请留意后续扣款通知", expected: "入账 0002 -900 JPY purchase hold @EXAMPLE.COM/JP TOKYO JPN 实扣38.37"),
        Sample(text: #"【招商银行】您绑定在Apple Pay上的账户0002（设备卡号0099）于10月21日16:28在EXAMPLE.COM/JP\TEST BUILDING\TOKYO\100-00完成扣款人民币38.37（交易预授权时间10月20日15:45）"#, expected: #"入账 0002 -38.37 CNY purchase posted @EXAMPLE.COM/JP\TEST BUILDING\TOKYO\100-00"#),
        Sample(text: "【招商银行】您账户0002于10月05日21:47在TESTPAY*A1B2C3D4E5 Test City CA预授权冻结USD0.80（人民币5.70），请留意后续扣款通知。", expected: "入账 0002 -0.80 USD purchase hold @TESTPAY*A1B2C3D4E5 Test City CA 实扣5.70"),
        Sample(text: #"【招商银行】您账户0002于10月06日17:25在TESTPAY*A1B2C3D4E5\1234 Test Road\Test完成扣款人民币5.70（交易预授权时间10月05日21:47）"#, expected: #"入账 0002 -5.70 CNY purchase posted @TESTPAY*A1B2C3D4E5\1234 Test Road\Test"#),
        Sample(text: "【招商银行】您账户0002于09月26日13:07在TEST-MERCHANT LIFESTY TAIPEI TWN预授权冻结TWD280.00（人民币57.27），请留意后续扣款通知。", expected: "入账 0002 -280.00 TWD purchase hold @TEST-MERCHANT LIFESTY TAIPEI TWN 实扣57.27"),
        Sample(text: #"【招商银行】您账户0002于09月30日12:56在TEST-MERCHANT LIFESTY\5F.,No.100,Test R完成扣款人民币57.27（交易预授权时间09月26日13:07）"#, expected: #"入账 0002 -57.27 CNY purchase posted @TEST-MERCHANT LIFESTY\5F.,No.100,Test R"#),
        Sample(text: "【招商银行】您账户0002于20260928的汇款 (845.92人民币) 已汇出，需收款人关注到账情况", expected: "入账 0002 -845.92 CNY transferOut posted"),
        Sample(text: "【招商银行】尊敬的客户，已将您开立的尾号0002账户的非柜面渠道支出限额设置为日限额3000.00元，年限额100000.00元（折合人民币金额），该限额是指在非柜台渠道发起各类出金交易（包括但不限于转账汇款、境外汇款、快捷支付、POS消费、ATM取款等）的统一限额，您可点击 example.cn/a/abc 或登录招商银行App搜索“非柜面限额”查询详情。如有疑问，请咨询网点工作人员。", expected: "忽略"),
        Sample(text: "【招商银行】尊敬的客户，您的万事达借记卡0002境外POS免密支付每日交易上限为人民币1500.00元。若当日累计免密支付金额超过该限额，交易将会失败。您可随时通过招商银行App调整该限额（搜索“万事达免密限额”或点击 example.cn/a/def )。请您妥善保管卡片，若遇遗失请及时通过我行客服电话95555或招商银行App申请挂失。", expected: "忽略"),

        // 众安：转账通知不写卡号，只添加了一张众安的卡，就是这张
        Sample(text: "【众安银行】ZA Bank:你于 2026-10-26 15:44:41 使用 ZA Card (0003) 在 ALP*QRCode0055 消费 HKD 0.25。如怀疑电 3665 3665。", expected: "入账 0003 -0.25 HKD purchase posted @ALP*QRCode0055"),
        Sample(text: "【众安银行】ZA Bank:你于 2026-10-04 18:34:37 使用 ZA Card (0003) 在 EXAMPLE PAY HONG KONG L 消费 HKD 11.92，并获得一次 2.5%「最股励」回赠机会，48 小时后失效。如怀疑电 3665 3665。", expected: "入账 0003 -11.92 HKD purchase posted @EXAMPLE PAY HONG KONG L"),
        Sample(text: #"【众安银行】ZA Bank:你已于 2026-10-09 18:52:14 将 CNY 365.03 转出至"100*0001"。交易类型：转出。如你无递交以上指示，可致电 +852 3665 3665。"#, expected: "入账 0003 -365.03 CNY transferOut posted @100*0001"),
        Sample(text: #"【众安银行】ZA Bank:You've paid HKD 80.00 to "100*0001" on 2026-09-23 13:36:39. Transaction type: Local transfer. Call +852 3665 3665 if you didn't do this."#, expected: "入账 0003 -80.00 HKD transferOut posted @100*0001"),
        Sample(text: #"【众安银行】ZA Bank:你已于 2026-09-22 09:45:44 将 HKD 90.00 转出至"u**@example .com"。交易类型：Email转出。如你无递交以上指示，可致电 +852 3665 3665。"#, expected: "入账 0003 -90.00 HKD transferOut posted @u**@example .com"),
        Sample(text: "【众安银行】ZA Bank:你通过「最股励」ZA Card 买入 TEST (测试股份) 0.0021 股的成交单已发出，请登入众安银行 App 查阅及下载成交单。", expected: "忽略"),
        Sample(text: "【众安银行】ZA Bank:你卖出 TEST (测试股份) 0.0031 股的订单已完全成交，成交详情为 0.0031 股 ＠ USD 123.4500 。请登入 ZA Bank App 查阅订单详情。", expected: "忽略"),

        // 恒生
        Sample(text: "【恒生銀行】恒生：你在29/10/2026透過結尾號碼0004的扣賬卡以「無卡支付」交易向WEIXIN*test shop Shenzhen CN支付了CNY2。如懷疑電28220228。", expected: "入账 0004 -2.00 CNY purchase posted @WEIXIN*test shop Shenzhen CN"),
        Sample(text: "【恒生銀行】恒生：你在23/09/2026透過結尾號碼0004的扣賬卡以「無卡支付」交易向EXAMPLE*SERVICE TOKYO JP支付了JPY2400。如懷疑電28220228。", expected: "入账 0004 -2400 JPY purchase posted @EXAMPLE*SERVICE TOKYO JP"),
        Sample(text: "【恒生銀行】恒生：你在20/09/2026透過結尾號碼0004的扣賬卡以「無卡支付」交易向TEST SHOP MAKATI PH支付了PHP75。如懷疑電28220228。", expected: "入账 0004 -75.00 PHP purchase posted @TEST SHOP MAKATI PH"),
        Sample(text: "【恒生銀行】恒生：你在28/08/2026透過結尾號碼0004的扣賬卡以「無卡支付」交易向12345 beijing CN支付了CNY80。如懷疑電28220228。", expected: "入账 0004 -80.00 CNY purchase posted @12345 beijing CN"),
        Sample(text: "【恒生银行】恒生：我們已按照有關指示，將結尾號碼0004的扣賬卡的海外自動櫃員機每日現金提款限額改為30000港元。生效日期：由22-07-26至直至另行通知。如懷疑電28228228。", expected: "忽略"),

        // 建行信用卡：「某某支付…公司」的「支付」是公司名称，「现金转出」是转走溢缴款
        Sample(text: "某某支付科技有限公司备付金11月06日11时48分向您尾号0005的龙卡信用卡存入人民币2.00元，入账后该卡本期人民币账单无需还款。[建设银行]", expected: "入账 0005 +2.00 CNY other posted @某某支付科技有限公司备付金"),
        Sample(text: "您尾号0005的龙卡信用卡11月07日23:20现金转出2.90元，当前的可用额度0.03元。[建设银行]", expected: "入账 0005 -2.90 CNY transferOut posted"),
        Sample(text: "【建设银行】您尾号0005的龙卡信用卡09月05日在支付宝-厦门某某…消费退货/退税53.00元，当前可用额度53.08元。", expected: "入账 0005 +53.00 CNY refund posted @支付宝-厦门某某"),

        // Maya：验证码里提到的交易还没发生
        Sample(text: "Never share this OTP-Maya will never ask for it. To continue your PHP 900.00 purchase at EXAMPLE using your Maya card ending in 0007, enter OTP 123456. If unauthorized, block your card in the app now. Expires in 5 minutes.", expected: "忽略"),
        Sample(text: "MAG-INGAT: You're transferring PHP 1,200.00 to account ending in 0008. If you're sure it's safe, use OTP 654321. Not you? Call 8845-7788.", expected: "忽略"),

        // 兴业 App 通知：没有署名，「*1234*」是卡号倒数第五到倒数第二位，这张卡后四位是 2345
        Sample(text: "您的借记卡*1234*于11月05日21:32支出0.01元，点击查看详情。", expected: "入账 2345 -0.01 CNY other posted"),
    ]

    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { now })
    }

    func addCards(_ backend: LedgerBackend) async throws {
        let cards: [(String?, String, String, CardType, CurrencyCode)] = [
            ("boc", "中国银行", "0001", .debit, .cny), ("boc", "中国银行", "0006", .debit, .cny), ("cmb", "招商银行", "0002", .debit, .cny),
            (nil, "众安银行", "0003", .debit, .hkd), (nil, "恒生银行", "0004", .debit, .hkd), ("ccb", "建设银行", "0005", .credit, .cny),
            ("cib", "兴业银行", "2345", .debit, .cny),
        ]
        for (bank, name, last4, type, currency) in cards {
            _ = try await backend.addAccount(AccountDraft(name: "", bankID: bank, bankName: name, last4: last4, cardType: type, currency: currency, paletteID: "ocean"))
        }
    }

    /// 这条通知最后记成了什么
    func describe(_ text: String, at date: Date, in backend: LedgerBackend) async throws -> String {
        let result = try await backend.ingest(IngestRequest(text: text, source: .auto, receivedAt: date))
        guard let ingestID = result.ingestID else { return "忽略" }
        var lines: [String] = []
        for row in try await backend.records(limit: 200) where row.record.ingestID == ingestID {
            let r = row.record
            let amount = MoneyFormat.plain(r.amountMinor, exponent: r.currency.minorUnitExponent, grouping: false)
            var line = "入账 \(row.last4) \(r.direction == .inflow ? "+" : "-")\(amount) \(r.currency) \(r.kind) \(r.status)"
            if let counterparty = r.counterparty { line += " @\(counterparty)" }
            if let settlement = r.settlementMinor, let charged = r.chargeCurrency {
                line += " 实扣" + MoneyFormat.plain(settlement, exponent: charged.minorUnitExponent, grouping: false)
            }
            lines.append(line)
        }
        for item in try await backend.openPendingItems() where item.ingestID == ingestID {
            guard let d = item.draft else {
                lines.append("待处理 \(item.reason)")
                continue
            }
            let sign = d.direction.map { $0 == .inflow ? "+" : "-" } ?? "?"
            let currency = d.amount.preferredCurrency ?? d.amount.currencyCandidates.first
            var line = "待处理 \(item.reason) \(sign)\(d.amount.digits) \(currency.map(\.rawValue) ?? "?") \(d.kind) \(d.status)"
            if let counterparty = d.counterparty { line += " @\(counterparty)" }
            lines.append(line)
        }
        return lines.isEmpty ? "忽略" : lines.joined(separator: " / ")
    }

    func testRealMessages() async throws {
        let backend = try makeBackend()
        try await addCards(backend)
        var wrong: [String] = []
        for (index, sample) in Self.samples.enumerated() {
            let actual = try await describe(sample.text, at: now.addingTimeInterval(Double(index) * 60), in: backend)
            if actual != sample.expected { wrong.append("#\(index + 1) 应为「\(sample.expected)」，实际「\(actual)」") }
        }
        print("真实样本：\(Self.samples.count - wrong.count)/\(Self.samples.count) 正确")
        for line in wrong { print(line) }
        XCTAssertEqual(wrong, [])
    }

    /// 快捷指令把同一条中行短信连着交过来几遍（中间没有空白或换了行）：只记一笔，不算金额有歧义；
    /// 之后再交一遍、或者交过来的遍数不同，都是重复的输入
    func testRepeatedCopiesOfOneMessage() async throws {
        let backend = try makeBackend()
        try await addCards(backend)
        let sms = "您的借记卡账户0001，于11月05日网上支付支取人民币0.01元,交易后余额13.13【中国银行】"
        let first = try await backend.ingest(IngestRequest(text: sms + sms + sms, source: .auto))
        XCTAssertEqual(first.recordedCount, 1)
        XCTAssertEqual(first.pendingCount, 0)
        for text in [sms, sms + "\n" + sms, sms + " " + sms + "\n" + sms] {
            let again = try await backend.ingest(IngestRequest(text: text, source: .auto))
            XCTAssertEqual(again.outcome, .duplicateInput, text)
        }
        let records = try await backend.records(limit: 10).map(\.record)
        XCTAssertEqual(records.map(\.amountMinor), [1])
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.count, 0)
        let stored = try await backend.ingestLog(limit: 10).first?.rawText
        XCTAssertEqual(stored, sms)
    }

    /// 两条不同的中行短信连在一起：「【中国银行】」后面就是下一条，各记一笔
    func testTwoBankOfChinaMessagesGlued() async throws {
        let backend = try makeBackend()
        try await addCards(backend)
        let pay = "您的借记卡账户0001，于11月05日网上支付支取人民币0.01元,交易后余额13.13【中国银行】"
        let income = "您的借记卡账户0001，于11月05日网上支付收入人民币0.02元,交易后余额13.15【中国银行】"
        let result = try await backend.ingest(IngestRequest(text: pay + income, source: .auto))
        XCTAssertEqual(result.recordedCount, 2)
        XCTAssertEqual(result.pendingCount, 0)
        let records = try await backend.records(limit: 10).map(\.record)
        XCTAssertEqual(Set(records.map { "\($0.direction) \($0.amountMinor) \($0.balanceAfterMinor ?? -1)" }), ["outflow 1 1313", "inflow 2 1315"])
    }

    /// 「1234*」：最后一位不显示。只填了后四位时比较重叠的三位，填了完整卡号时倒数第五位也要对上
    func testTailWithHiddenLastDigit() {
        var card = Account(id: "a", name: "", bankID: "cib", bankName: "兴业银行", last4: "2345", cardType: .debit, currency: .cny, paletteID: "ocean", sortOrder: 0, createdAt: now)
        XCTAssertTrue(card.matches(tail: "1234*"))
        XCTAssertTrue(card.matches(tail: "2345"))
        XCTAssertFalse(card.matches(tail: "2345*"))
        XCTAssertFalse(card.matches(tail: "1235*"))
        card.cardNumber = "6229000000012345"
        XCTAssertTrue(card.matches(tail: "1234*"))
        card.cardNumber = "6229000000092345"
        XCTAssertFalse(card.matches(tail: "1234*"))
    }

    func testSingleCopy() {
        let sms = "您的借记卡账户0001，于11月05日网上支付支取人民币0.01元,交易后余额13.13【中国银行】"
        XCTAssertEqual(TextNormalizer.singleCopy(sms + sms + sms), sms)
        XCTAssertEqual(TextNormalizer.singleCopy("\n" + sms + "\n\n" + sms + " "), sms)
        XCTAssertEqual(TextNormalizer.singleCopy(sms), sms)
        XCTAssertEqual(TextNormalizer.singleCopy(sms + sms + "。"), sms + sms + "。", "不是正好几遍的不动")
        XCTAssertEqual(TextNormalizer.singleCopy("哈哈哈哈哈哈哈哈"), "哈哈哈哈哈哈哈哈", "太短的不动")
    }

    /// 三笔完成扣款各自了结对应的冻结，中行那笔没有完成扣款的通知，还冻结着
    func testCapturesCloseTheirHolds() async throws {
        let backend = try makeBackend()
        try await addCards(backend)
        for (index, sample) in Self.samples.enumerated() {
            _ = try await backend.ingest(IngestRequest(text: sample.text, source: .auto, receivedAt: now.addingTimeInterval(Double(index) * 60)))
        }
        let rows = try await backend.records(limit: 200)
        XCTAssertEqual(rows.filter { $0.record.status == .holdReleased }.count, 0, "了结的冻结收进扣款里，列表里不单独显示")
        var closed = 0
        for row in rows where row.record.status == .posted { closed += try await backend.recordDetail(id: row.id).closedHolds.count }
        XCTAssertEqual(closed, 3)
        XCTAssertEqual(rows.filter { $0.record.status == .hold }.map(\.record.currency), [.usd])
    }

    /// 还没添加这些卡时：交易都等用户选卡，不会记到别处；不是交易的照样忽略
    func testWithoutCardsNothingIsRecorded() async throws {
        let backend = try makeBackend()
        var wrong: [String] = []
        for (index, sample) in Self.samples.enumerated() {
            let actual = try await describe(sample.text, at: now.addingTimeInterval(Double(index) * 60), in: backend)
            let good = sample.expected == "忽略" ? actual == "忽略" : actual.hasPrefix("待处理")
            if !good { wrong.append("#\(index + 1) 实际「\(actual)」") }
        }
        XCTAssertEqual(wrong, [])
    }
}
