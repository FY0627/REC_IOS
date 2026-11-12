import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 用户在本机做的识别模板。样例都是脱敏文本。
final class TemplateTests: XCTestCase {
    func cleaned(_ text: String, source: SourceKind = .sms) -> String {
        MessageParser.cleaned(text, source: source)
    }

    func range(of part: String, in text: String) -> NSRange {
        NSString(string: text).range(of: part)
    }

    func template(_ pieces: [TemplatePiece], kind: TransactionKind = .transferOut, direction: FlowDirection = .outflow) -> MessageTemplate {
        MessageTemplate(id: UUID().uuidString, name: "测试", pieces: pieces, kind: kind, direction: direction, createdAt: ParserSampleTests.reference)
    }

    func makeBackend() throws -> LedgerBackend {
        let now = ParserSampleTests.reference
        return LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { now })
    }

    @discardableResult
    func addAccount(_ backend: LedgerBackend) async throws -> Account {
        try await backend.addAccount(AccountDraft(name: "", bankID: "x", bankName: "某某银行", last4: "5566", cardType: .debit, currency: .hkd, paletteID: "ocean"))
    }

    func testBuildKeepsWordingAndDropsNumbers() throws {
        let sample = cleaned(ParserSampleTests.phoneTransfer)
        let pieces = try MessageTemplates.build(
            sample: sample, amount: range(of: "23.75", in: sample), cardTail: nil, counterparty: range(of: "+86-138******00", in: sample)
        ).get()
        let t = template(pieces)
        XCTAssertEqual(t.preview, #"【众安银行】ZA Bank:你已于 # # 将 HKD 【金额】 转出至"【对方】""#)
        XCTAssertFalse(t.preview.contains("2026"), "原文的数字不保存")

        let next = cleaned(#"【众安银行】ZA Bank:你已于 2026-03-20 08:12:40 将 HKD 1,200.00 转出至"+86-138******11"。交易类型：手机号转出。"#)
        let hit = try XCTUnwrap(MessageTemplates.match(t, in: next))
        XCTAssertEqual(hit.amount.digits, "1,200.00")
        XCTAssertEqual(hit.amount.currencyCandidates, [.hkd])
        XCTAssertEqual(hit.counterparty, "+86-138******11")
        XCTAssertNil(MessageTemplates.match(t, in: cleaned("【众安银行】ZA Bank:你已于 2026-03-20 08:12:40 收到 HKD 50.00")), "文字不同的通知不认")
    }

    func testWideSelectionIsNarrowedToTheNumber() throws {
        let sample = cleaned("【某某银行】你的账户 5566 有一笔 HKD 88.20 的变动，对方：陈大文。")
        let pieces = try MessageTemplates.build(
            sample: sample, amount: range(of: "HKD 88.20", in: sample), cardTail: range(of: "账户 5566", in: sample), counterparty: range(of: "陈大文。", in: sample)
        ).get()
        XCTAssertEqual(pieces.filter { $0 == .amount || $0 == .cardTail || $0 == .counterparty }, [.cardTail, .amount, .counterparty])
        let hit = try XCTUnwrap(MessageTemplates.match(template(pieces), in: sample))
        XCTAssertEqual(hit.amount.digits, "88.20")
        XCTAssertEqual(hit.cardTail, "5566")
        XCTAssertEqual(hit.counterparty, "陈大文")
    }

    /// 编辑已有的模板：还原成示例通知、圈好位置，原样再做一次得到同样的写法
    func testSampleRebuildsTheSameTemplate() throws {
        let samples: [(String, String, String?, String?)] = [
            (cleaned(ParserSampleTests.phoneTransfer), "23.75", nil, "+86-138******00"),
            (cleaned("【某某银行】你的账户 5566 有一笔 HKD 88.20 的变动，对方：陈大文。"), "88.20", "5566", "陈大文"),
            (cleaned("您好\n您尾号5566的卡\n收到一笔款项\nHKD 275.40", source: .email), "275.40", "5566", nil),
        ]
        for (text, amount, tail, counterparty) in samples {
            let pieces = try MessageTemplates.build(
                sample: text, amount: range(of: amount, in: text), cardTail: tail.map { range(of: $0, in: text) },
                counterparty: counterparty.map { range(of: $0, in: text) }
            ).get()
            let sample = MessageTemplates.sample(pieces)
            let again = try MessageTemplates.build(
                sample: sample.text, amount: try XCTUnwrap(sample.amount), cardTail: sample.cardTail, counterparty: sample.counterparty
            ).get()
            XCTAssertEqual(again, pieces, sample.text)
            XCTAssertNotNil(MessageTemplates.match(template(pieces), in: sample.text), "示例通知认得出")
        }
    }

    /// 改过的模板按原来的标识保存：不多出一个，待处理里同样写法的通知按改过的重新识别
    func testEditedTemplateReplacesTheOldOne() async throws {
        let backend = try makeBackend()
        try await addAccount(backend)
        let sample = cleaned("【某某银行】你的账户 5566 有一笔 HKD 88.20 的变动，对方：陈大文。")
        let pieces = try MessageTemplates.build(sample: sample, amount: range(of: "88.20", in: sample), cardTail: range(of: "5566", in: sample), counterparty: nil).get()
        var t = template(pieces, kind: .purchase, direction: .outflow)
        _ = try await backend.saveTemplate(t)
        t.name = "改过的名字"
        t.kind = .transferIn
        t.direction = .inflow
        _ = try await backend.saveTemplate(t)
        let saved = try await backend.templates()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.name, "改过的名字")
        XCTAssertEqual(saved.first?.kind, .transferIn)
        XCTAssertEqual(saved.first?.createdAt, t.createdAt)
    }

    /// 编辑页只分支出 / 收入 / 转帐：原来的性质不换类就保留，换了类按新的一类
    func testEntryTypeKeepsTheOriginalKind() {
        let kept: [(TransactionKind, FlowDirection)] = [
            (.purchase, .outflow), (.fee, .outflow), (.interestCharge, .outflow), (.refund, .inflow), (.reversal, .inflow),
            (.income, .inflow), (.salary, .inflow), (.interestIncome, .inflow),
            (.transferOut, .outflow), (.transferIn, .inflow), (.repayment, .inflow), (.repayment, .outflow),
            (.deposit, .inflow), (.withdrawal, .outflow),
        ]
        for (kind, direction) in kept {
            let entry = MessageTemplate.entry(kind: kind, direction: direction)
            let fields = MessageTemplate.fields(type: entry.type, refund: entry.refund, transferDirection: direction, keeping: kind)
            XCTAssertEqual(fields.kind, kind, "\(kind) \(direction)")
            XCTAssertEqual(fields.direction, direction, "\(kind) \(direction)")
        }

        XCTAssertEqual(MessageTemplate.entry(kind: .transferOut, direction: .outflow).type, .transfer)
        XCTAssertEqual(MessageTemplate.entry(kind: .other, direction: .inflow).type, .income)
        XCTAssertTrue(MessageTemplate.entry(kind: .refund, direction: .inflow).refund)

        let toIncome = MessageTemplate.fields(type: .income, refund: false, transferDirection: .outflow, keeping: .purchase)
        XCTAssertEqual(toIncome.kind, .income)
        XCTAssertEqual(toIncome.direction, .inflow)
        let toRefund = MessageTemplate.fields(type: .expense, refund: true, transferDirection: .outflow, keeping: .purchase)
        XCTAssertEqual(toRefund.kind, .refund)
        XCTAssertEqual(toRefund.direction, .inflow)
        let transferIn = MessageTemplate.fields(type: .transfer, refund: false, transferDirection: .inflow, keeping: .withdrawal)
        XCTAssertEqual(transferIn.kind, .transferIn)
        let expense = MessageTemplate.fields(type: .expense, refund: false, transferDirection: .outflow, keeping: .other)
        XCTAssertEqual(expense.kind, .purchase)
    }

    func testTooFewWordsIsRejected() {
        let sample = "HKD 275.40"
        XCTAssertEqual(MessageTemplates.build(sample: sample, amount: range(of: "275.40", in: sample), cardTail: nil, counterparty: nil), .failure(.tooGeneric))
    }

    func testOverlappingMarksAreRejected() {
        let sample = cleaned("【某某银行】你的账户 5566 有一笔 HKD 88.20 的变动")
        let amount = range(of: "88.20", in: sample)
        XCTAssertEqual(MessageTemplates.build(sample: sample, amount: amount, cardTail: nil, counterparty: amount), .failure(.overlapping))
    }

    func testEmailAmountOnItsOwnLineTakesEarlierLines() throws {
        let sample = cleaned(IngestTests.hangSengTransferEmail, source: .email)
        let pieces = try MessageTemplates.build(sample: sample, amount: range(of: "275.40", in: sample), cardTail: nil, counterparty: nil).get()
        let t = template(pieces)
        XCTAssertTrue(t.preview.contains("From"), t.preview)
        let other = cleaned(IngestTests.hangSengTransferEmail.replacingOccurrences(of: "HKD275.40", with: "HKD100.00"), source: .email)
        XCTAssertEqual(MessageTemplates.match(t, in: other)?.amount.digits, "100.00")
    }

    // MARK: 入账

    static let unknownWording = "【某某银行】你的账户 5566 有一笔 HKD 88.20 的变动，对方：陈大文。"

    func testSavedTemplateReappliesToPendingAndRecognizesNewMessages() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend)

        // 通用读法看不出是进是出：进待处理
        let first = try await backend.ingest(IngestRequest(text: Self.unknownWording, source: .sms))
        XCTAssertEqual(first.outcome, .pending, first.summary)
        let items = try await backend.openPendingItems()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.reason, .uncertainKind)

        // 用这条待处理做模板：保存后它按模板入账
        let sample = MessageParser.cleaned(try XCTUnwrap(item.rawText), source: item.source)
        let pieces = try MessageTemplates.build(
            sample: sample, amount: range(of: "88.20", in: sample), cardTail: range(of: "5566", in: sample), counterparty: range(of: "陈大文", in: sample)
        ).get()
        let reapplied = try await backend.saveTemplate(template(pieces, kind: .purchase, direction: .outflow))
        XCTAssertEqual(reapplied, 1)
        let pendingAfter = try await backend.pendingCount()
        XCTAssertEqual(pendingAfter, 0)
        var rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.first?.record.amountMinor, 88_20)
        XCTAssertEqual(rows.first?.record.kind, .purchase)
        XCTAssertEqual(rows.first?.record.counterparty, "陈大文")

        // 之后同样写法的通知直接按模板入账
        let next = try await backend.ingest(IngestRequest(text: "【某某银行】你的账户 5566 有一笔 HKD 12.00 的变动，对方：李小明。", source: .sms))
        XCTAssertEqual(next.outcome, .recorded, next.summary)
        rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.record.counterparty)), ["陈大文", "李小明"])

        let saved = try await backend.templates()
        XCTAssertEqual(saved.count, 1)
        try await backend.deleteTemplate(id: saved[0].id)
        let remaining = try await backend.templates()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// 流水上点「不记」：这笔删掉，记住这种写法（数字换成任意数字），以后同样写法的通知不记；别的通知照常记
    func testSkipRecordRemembersTheWording() async throws {
        let backend = try makeBackend()
        try await addAccount(backend)
        let first = try await backend.ingest(IngestRequest(text: "【某某银行】您尾号5566的账户于11月12日发起活期宝转入，交易金额：港币88.20元。", source: .sms))
        let id = try XCTUnwrap(first.items.first?.recordID)
        let saved = try await backend.skipRecord(id: id)
        XCTAssertEqual(saved, 1)
        let left = try await backend.records(limit: 10)
        XCTAssertEqual(left.count, 0)
        let rules = try await backend.templates()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertTrue(rule.isSkip)
        XCTAssertFalse(rule.preview.contains("5566"), "原文的数字不保存")
        XCTAssertFalse(rule.preview.contains("88"), "原文的数字不保存")

        let next = try await backend.ingest(IngestRequest(text: "【某某银行】您尾号5566的账户于11月13日发起活期宝转入，交易金额：港币1,000.00元。", source: .sms))
        XCTAssertEqual(next.classification, .skipped)
        XCTAssertEqual(next.recordedCount, 0)
        XCTAssertEqual(next.pendingCount, 0)
        XCTAssertTrue(next.items.isEmpty, "不发记账结果通知")

        let purchase = try await backend.ingest(IngestRequest(text: "【某某银行】您尾号5566的账户于11月13日消费港币30.00元。", source: .sms))
        XCTAssertEqual(purchase.recordedCount, 1, "别的写法照常记")
        let after = try await backend.templates()
        XCTAssertEqual(after.count, 1)
    }

    /// 朝朝宝的转入、转出：和卡算一个整体，不记，也不进待处理
    func testBalanceProductMovesAreSkipped() async throws {
        let backend = try makeBackend()
        try await addAccount(backend)
        for text in ["您尾号5566的账户于11月12日发起朝朝宝转入，交易金额：人民币2199.99元。", "您尾号5566的账户于11月13日发起朝朝宝转出，交易金额：人民币100.00元。"] {
            let result = try await backend.ingest(IngestRequest(text: text, source: .auto))
            XCTAssertEqual(result.classification, .skipped, text)
            XCTAssertEqual(result.recordedCount + result.pendingCount, 0, text)
        }
    }

    func testTemplateDoesNotOverrideVerificationCode() async throws {
        let backend = try makeBackend()
        try await addAccount(backend)
        let sample = cleaned(Self.unknownWording)
        let pieces = try MessageTemplates.build(sample: sample, amount: range(of: "88.20", in: sample), cardTail: range(of: "5566", in: sample), counterparty: nil).get()
        _ = try await backend.saveTemplate(template(pieces, kind: .purchase))
        let result = try await backend.ingest(IngestRequest(text: "【某某银行】你的账户 5566 有一笔 HKD 12.00 的变动，验证码 834211，请勿泄露。", source: .sms))
        XCTAssertEqual(result.classification, .verificationCode)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
    }
}
