import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

final class IngestTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    let now = ParserSampleTests.reference

    func makeBackend(path: String? = nil) throws -> LedgerBackend {
        let now = self.now
        let database = try path.map { try Database(path: $0) } ?? Database.inMemory()
        return LedgerBackend(database: database, calendar: calendar, clock: { now })
    }

    func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-ingest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.sqlite").path
    }

    @discardableResult
    func addAccount(_ backend: LedgerBackend, bank: String = "cmb", bankName: String = "招商银行", last4: String, type: CardType = .debit, currency: CurrencyCode = .cny) async throws -> Account {
        try await backend.addAccount(AccountDraft(name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: currency, paletteID: "ocean"))
    }

    let purchase = "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元，余额1,234.56元。"

    // MARK: 基本入账

    func testPurchaseIsRecordedWithAllFields() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        XCTAssertEqual(result.outcome, .recorded)
        XCTAssertEqual(result.recordedCount, 1)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        let r = rows[0].record
        XCTAssertEqual(r.accountID, account.id)
        XCTAssertEqual(r.amountMinor, 3800)
        XCTAssertEqual(r.currency, .cny)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.counterparty, "星巴克咖啡")
        XCTAssertEqual(r.balanceAfterMinor, 123_456)
        XCTAssertNil(r.receivedAt, "系统没提供接收时间时不伪造")
        XCTAssertEqual(r.processedAt, now)
        XCTAssertEqual(rows[0].last4, "0427")
        let status = try await backend.automationStatus()
        XCTAssertEqual(status[account.id]?.lastSuccessAt, now)
        XCTAssertEqual(status[account.id]?.lastSuccessSource, .sms)
    }

    func testIngestResultListsEachTransactionForNotifications() async throws {
        let backend = try makeBackend()
        // 还没有这张卡：进入待处理，只有通知里写的尾号和金额原文
        let pending = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        let item = try XCTUnwrap(pending.items.first)
        XCTAssertEqual(pending.items.count, 1)
        XCTAssertEqual(item.cardTail, "0427")
        XCTAssertEqual(item.kind, .purchase)
        XCTAssertNil(item.amountMinor)
        XCTAssertEqual(item.amountText, "38.00")
        XCTAssertEqual(item.result, .pending(.noMatchingAccount))

        try await addAccount(backend, last4: "0427")
        let text = "【招商银行】您尾号0427的储蓄卡于10月24日15:10在全家消费人民币12.50元。"
        let recorded = try await backend.ingest(IngestRequest(text: text, source: .sms, sender: "95555"))
        let recordID = try XCTUnwrap(recorded.items.first?.recordID, "通知上选分类要用到流水标识")
        XCTAssertEqual(recorded.items, [
            IngestItem(cardTail: "0427", kind: .purchase, status: .posted, amountMinor: 1250, currency: .cny, amountText: nil, result: .recorded, recordID: recordID),
        ])

        let unrecognized = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0427的账户有一笔变动，详情请查看App", source: .sms, sender: "95555"))
        XCTAssertTrue(unrecognized.items.allSatisfy { $0.result != .recorded })
    }

    func testAccountCurrencyUsedWhenMessageHasNone() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "x", bankName: "Example Bank", last4: "3305", currency: .eur)
        _ = try await backend.ingest(IngestRequest(text: "Card ending 3305 debited 12,50 for purchase at REWE on 24.10.2026 13:02", source: .sms))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.currency, .eur)
        XCTAssertEqual(r.amountMinor, 1250)
    }

    // MARK: 幂等与并发

    func testSameInputTwiceIsIdempotent() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        let second = try await backend.ingest(IngestRequest(text: purchase + "  ", source: .sms, sender: "95555"))
        XCTAssertEqual(second.outcome, .duplicateInput)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testConcurrentSameInputRecordsOnce() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let text = purchase
        try await withThrowingTaskGroup(of: IngestResult.self) { group in
            for _ in 0..<20 { group.addTask { try await backend.ingest(IngestRequest(text: text, source: .sms, sender: "95555")) } }
            for try await _ in group {}
        }
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testTwoConnectionsToSameFileDoNotDoubleRecord() async throws {
        // 模拟两个自动化同时命中、由两个独立连接写入同一个数据库文件
        let path = tempPath()
        let first = try makeBackend(path: path)
        try await addAccount(first, last4: "0427")
        let second = try makeBackend(path: path)
        let text = purchase
        async let a = first.ingest(IngestRequest(text: text, source: .sms, sender: "95555"))
        async let b = second.ingest(IngestRequest(text: text, source: .sms, sender: "95555"))
        let outcomes = try await [a.outcome, b.outcome].sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(Set(outcomes), [.recorded, .duplicateInput])
        let count = try await first.recordCount()
        XCTAssertEqual(count, 1)
    }

    func testDistinctIdenticalTextsWithDifferentReceivedTimesAreNotSilentlyMerged() async throws {
        // 两条完全相同的短信、系统给出不同接收时间：可能是两笔真实交易，不能静默合并
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let text = "您尾号0427账户10月24日14:30消费5.00元【招商银行】"
        _ = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: now.addingTimeInterval(-60)))
        let second = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: now))
        XCTAssertEqual(second.outcome, .pending)
        let pending = try await backend.openPendingItems()
        XCTAssertEqual(pending.first?.reason, .possibleDuplicate)
        // 用户确认是另一笔真实交易
        try await backend.confirmPending(id: pending[0].id, accountID: pending[0].candidateAccountIDs[0])
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: 跨来源

    func testSmsAndEmailForSameTransactionMerge() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427的储蓄卡于2026年10月24日14:30消费人民币38.00元。【招商银行】", source: .sms, sender: "95555"))
        let email = try await backend.ingest(IngestRequest(text: "<p>您尾号0427的储蓄卡于2026-10-24 14:30在星巴克咖啡消费人民币38.00元。</p>", source: .email, sender: "notice@cmbchina.com", subject: "交易提醒"))
        XCTAssertEqual(email.outcome, .mergedDuplicate)
        XCTAssertEqual(email.items.map(\.result), [.merged], "合并的一笔不再发「记账成功」通知")
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        let detail = try await backend.recordDetail(id: rows[0].id)
        XCTAssertEqual(Set(detail.evidence.map(\.source)), [.sms, .email])
    }

    func testOneAutomationForAllSourcesDoesNotDoubleCount() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        // 同一笔交易的短信和银行 App 通知交给同一个自动化，来源都是「自动」
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427的储蓄卡于2026年10月24日14:30消费人民币38.00元。【招商银行】", source: .auto))
        let notification = try await backend.ingest(IngestRequest(text: "招商银行：尾号0427储蓄卡10月24日14:30消费38.00元", source: .auto))
        XCTAssertEqual(notification.outcome, .mergedDuplicate, notification.summary)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)

        // 没有分钟级时间：近似重复进待处理，不直接记两笔
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户消费人民币12.00元【招商银行】", source: .auto))
        let weak = try await backend.ingest(IngestRequest(text: "招商银行：尾号0427账户消费12.00元", source: .auto))
        XCTAssertEqual(weak.outcome, .pending, weak.summary)
    }

    func testWeakCrossSourceMatchGoesToPending() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户消费人民币38.00元【招商银行】", source: .sms))
        let email = try await backend.ingest(IngestRequest(text: "您尾号0427的储蓄卡消费人民币38.00元。", source: .email, sender: "notice@cmbchina.com"))
        XCTAssertEqual(email.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .possibleDuplicate)
        try await backend.ignorePending(id: item.id)
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 1, "用户确认重复：不新增，原记录增加来源证据")
        let detail = try await backend.recordDetail(id: rows[0].id)
        XCTAssertEqual(detail.evidence.count, 2)
    }

    func testSameAmountSameMerchantSameSourceDifferentTimesAreBothKept() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:01在地铁消费3.00元，余额100.00元【招商银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:40在地铁消费3.00元，余额97.00元【招商银行】", source: .sms))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: 账户匹配

    func testSameTailAcrossBanksUsesSender() async throws {
        let backend = try makeBackend()
        let cmb = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms, sender: "95555"))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, cmb.id)
    }

    func testSameTailWithoutBankEvidenceGoesToPendingAndCanBeConfirmed() async throws {
        let backend = try makeBackend()
        let cmb = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        let result = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .ambiguousAccount)
        XCTAssertEqual(item.candidateAccountIDs.count, 2)
        try await backend.confirmPending(id: item.id, accountID: cmb.id)
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, cmb.id)
        XCTAssertEqual(r.amountMinor, 2000)
        let remaining = try await backend.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    func testBoundAccountResolvesSameTail() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        let icbc = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms, boundAccountID: icbc.id))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, icbc.id)
    }

    func testBoundAccountDoesNotOverrideDifferentTail() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "1111")
        let b = try await addAccount(backend, last4: "2222")
        _ = try await backend.ingest(IngestRequest(text: "您尾号2222账户10月24日消费20.00元【招商银行】", source: .sms, boundAccountID: a.id))
        let r = try await backend.records()[0].record
        XCTAssertEqual(r.accountID, b.id, "正文尾号优先于自动化绑定")
    }

    func testMessageWithoutTailNeedsConfirmation() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "1111")
        try await addAccount(backend, last4: "2222")
        let result = try await backend.ingest(IngestRequest(text: "【招商银行】您的账户10月24日消费20.00元", source: .email, boundAccountID: a.id))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .missingCardTail)
        XCTAssertEqual(item.candidateAccountIDs, [a.id])
    }

    func testNotificationBeforeAccountCreationIsRecordedAfterAdding() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: purchase, source: .sms, sender: "95555"))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .noMatchingAccount)
        try await addAccount(backend, last4: "0427")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
        let open = try await backend.pendingCount()
        XCTAssertEqual(open, 0)
    }

    func testPendingCannotBeUsedForManualEntry() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "1234")
        let other = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "9999")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: "您尾号1234账户10月24日消费20.00元", source: .sms))
        let item = try await backend.openPendingItems()[0]
        do {
            try await backend.confirmPending(id: item.id, accountID: other.id)
            XCTFail("不在候选里的账户不能确认")
        } catch BackendError.accountNotACandidate {}
        _ = a
        // 无法识别的通知只能忽略
        try await addAccount(backend, bank: "x", bankName: "某银行", last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "【某银行】您尾号0427的账户信息已更新。", source: .sms))
        let unrecognized = try await backend.openPendingItems().first { $0.reason == .unrecognized }!
        do {
            try await backend.confirmPending(id: unrecognized.id, accountID: a.id)
            XCTFail("无法识别的通知不能确认入账")
        } catch BackendError.confirmationNotAllowed {}
    }

    // MARK: 非交易信息

    func testFilteredMessagesAreLoggedNotDropped() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】验证码：482913，您正在支付100.00元。", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】尊敬的客户，分期优惠，最高可借50,000元，回T退订", source: .sms))
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(Set(log.map(\.classification)), [.verificationCode, .marketing])
        XCTAssertNil(log.first { $0.classification == .verificationCode }?.rawText, "验证码正文不保存")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
    }

    func testEmptyInputIsLogged() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: "   ", source: .sms))
        XCTAssertEqual(result.classification, .empty)
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.first?.classification, .empty)
    }

    func testFailedAndHoldAreKeptButNotCounted() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月24日在苹果商店消费68.00元交易失败。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月24日在某某酒店预授权人民币2,000.00元。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(Set(rows.map(\.record.status)), [.failed, .hold])
        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertTrue(stats.currencies.isEmpty)
        XCTAssertEqual(stats.failedCount, 1)
        XCTAssertEqual(stats.holdCount, 1)
    }

    // MARK: 余额

    func testBankBalanceInMessageIsNotUsed() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元，余额900.00元【招商银行】", source: .sms))
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.ledgerDerivedMinor, 0, "通知里写的余额不使用（没填余额从 0 开始，这笔和添加同时到达）")
        let rows = try await backend.records()
        XCTAssertEqual(rows.first?.record.balanceAfterMinor, 90_000, "流水上仍保留通知里写的余额")
    }

    func testBalanceStartsAtZeroWhenNotFilled() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        XCTAssertEqual(account.openingBalanceMinor, 0, "添加时没填余额：从 0 开始")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.ledgerDerivedMinor, -10_00)
    }

    // MARK: 多币种账户

    func testMultiCurrencyAccountKeepsBalancesPerCurrency() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: nil, bankName: "恒生银行", last4: "0105", cardType: .debit, currency: .hkd, paletteID: "ocean",
            openingBalanceMinor: 1_000_00, extraCurrencies: [.usd, .hkd, .cny], extraOpeningBalances: [.usd: 200_00]
        ))
        XCTAssertEqual(account.extraCurrencies, [.usd, .cny], "主币种和重复项被去掉")
        XCTAssertEqual(account.currencies, [.hkd, .usd, .cny])

        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日14:30消费美元12.50元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日15:30消费港币100.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(120)))
        // 只写了「元」：记为主币种
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日16:30消费20.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(180)))
        // ¥ 在中文通知里可能是人民币或日元：账户持有人民币，记为人民币（收入：人民币余额是 0，消费会换成港币扣）
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日17:30收入¥30.00【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(240)))

        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(Set(rows.map(\.record.currency)), [.usd, .hkd, .cny])

        let summaries = try await backend.balanceSummaries()
        let balances = try XCTUnwrap(summaries[account.id])
        XCTAssertEqual(balances.items.map(\.currency), [.hkd, .usd, .cny])
        XCTAssertEqual(balances.item(.hkd)?.ledgerDerivedMinor, 1_000_00 - 100_00 - 20_00)
        XCTAssertEqual(balances.item(.usd)?.ledgerDerivedMinor, 200_00 - 12_50)
        XCTAssertEqual(balances.item(.cny)?.ledgerDerivedMinor, 30_00, "人民币没填余额，从 0 开始")

        try await backend.setOpeningBalance(accountID: account.id, currency: .cny, amountMinor: 500_00)
        var updated = try await backend.balanceSummaries()[account.id]
        XCTAssertEqual(updated?.item(.cny)?.ledgerDerivedMinor, 500_00 + 30_00, "之后到达的人民币流水加到初始余额上")

        // 去掉人民币：它的初始余额一起删除，已有流水保留
        try await backend.updateCardInfo(accountID: account.id, name: "", cardNumber: nil, extraCurrencies: [.usd])
        let stored = try await backend.accounts().first { $0.id == account.id }
        XCTAssertEqual(stored?.extraCurrencies, [.usd])
        XCTAssertNil(stored?.openingBalance(.cny))
        updated = try await backend.balanceSummaries()[account.id]
        XCTAssertEqual(updated?.items.map(\.currency), [.hkd, .usd])
        let count = try await backend.recordCount(accountID: account.id)
        XCTAssertEqual(count, 4)
    }

    /// 恒生的多币种扣账卡：交易币种的余额不够时，整笔换成港币扣（ADR 0018）。通知只写交易金额，港币按汇率估算
    func testPurchaseBeyondCurrencyBalanceIsChargedToPrimary() async throws {
        let backend = try makeBackend()
        try await backend.saveExchangeRates(ExchangeRates(base: .usd, rates: ["USD": 1, "HKD": 7.8, "CNY": 7.2], updatedAt: now, fetchedAt: now))
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: nil, bankName: "恒生银行", last4: "0105", cardType: .debit, currency: .hkd, paletteID: "ocean",
            openingBalanceMinor: 1_000_00, extraCurrencies: [.cny], extraOpeningBalances: [.cny: 50_00]
        ))
        func pay(_ amount: String, _ minutes: Double) async throws -> IngestResult {
            try await backend.ingest(IngestRequest(
                text: "【恒生銀行】恒生：你在24/10/2026透過結尾號碼0105的扣賬卡以「無卡支付」交易向WEIXIN*test shop Shenzhen CN支付了\(amount)。如懷疑電28220228。",
                source: .auto, receivedAt: now.addingTimeInterval(minutes * 60)
            ))
        }

        // 人民币只有 50，这笔 80：整笔按港币扣，80 人民币 = 11.11 美元 = 86.67 港币
        let short = try await pay("CNY80", 1)
        let item = try XCTUnwrap(short.items.first)
        XCTAssertEqual(item.charge?.currency, .hkd)
        XCTAssertEqual(item.charge?.amountMinor, 86_67)
        XCTAssertEqual(item.charge?.isActual, false)
        XCTAssertTrue(item.insufficientBalance)
        var rows = try await backend.records(accountID: account.id)
        var record = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(record.currency, .cny, "流水仍是人民币 80")
        XCTAssertEqual(record.chargeCurrency, .hkd, "入账时记下从港币扣，之后余额变了也不改")
        XCTAssertNil(record.settlementMinor)

        // 人民币够：扣人民币
        let enough = try await pay("CNY20", 2)
        XCTAssertNil(enough.items.first?.charge)
        rows = try await backend.records(accountID: account.id)
        record = try XCTUnwrap(rows.first?.record)
        XCTAssertNil(record.chargeCurrency)

        // 港币是主币种，不够也没有别的币种可换
        _ = try await pay("HKD2000", 3)
        rows = try await backend.records(accountID: account.id)
        record = try XCTUnwrap(rows.first?.record)
        XCTAssertNil(record.chargeCurrency)

        let summaries = try await backend.balanceSummaries()
        let balances = try XCTUnwrap(summaries[account.id])
        XCTAssertEqual(balances.item(.cny)?.ledgerDerivedMinor, 50_00 - 20_00)
        XCTAssertEqual(balances.item(.hkd)?.ledgerDerivedMinor, 1_000_00 - 86_67 - 2_000_00)

        // 按币种看流水：换成港币扣的那笔在港币里，不在人民币里
        let hkdRows = try await backend.records(filter: RecordFilter(accountID: account.id, currency: .hkd))
        XCTAssertEqual(hkdRows.map(\.record.amountMinor).sorted(), [80_00, 2_000_00])
        XCTAssertEqual(hkdRows.first { $0.record.currency == .cny }?.charge?.amountMinor, 86_67)
        let cnyRows = try await backend.records(filter: RecordFilter(accountID: account.id, currency: .cny))
        XCTAssertEqual(cnyRows.map(\.record.amountMinor), [20_00])
    }

    /// 可用余额要减去还没结清的冻结：冻结之后人民币不够下一笔，下一笔换成主币种扣
    func testOpenHoldsCountAgainstAvailableBalance() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "boc", bankName: "中国银行", last4: "0006", cardType: .debit, currency: .cny, paletteID: "ocean",
            openingBalanceMinor: 100_00, extraCurrencies: [.usd], extraOpeningBalances: [.usd: 10_00]
        ))
        _ = try await backend.ingest(IngestRequest(
            text: "您的借记卡0006于0618发生双信息无卡消费交易，金额8.00美元，已冻结8.00美元。【中国银行】", source: .auto, receivedAt: now.addingTimeInterval(60)
        ))
        var rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.first?.record.status, .hold)
        XCTAssertNil(rows.first?.record.chargeCurrency, "冻结前美元有 10，够")

        var summaries = try await backend.balanceSummaries()
        var usd = try XCTUnwrap(summaries[account.id]?.item(.usd))
        XCTAssertEqual(usd.ledgerDerivedMinor, 10_00, "冻结不动余额")
        XCTAssertEqual(usd.openHoldsMinor, 8_00)
        XCTAssertEqual(usd.availableMinor, 2_00)

        _ = try await backend.ingest(IngestRequest(
            text: "您的借记卡账户0006，于06月19日网上支付支取美元5.00元【中国银行】", source: .auto, receivedAt: now.addingTimeInterval(120)
        ))
        rows = try await backend.records(accountID: account.id)
        let paid = try XCTUnwrap(rows.first { $0.record.status == .posted }?.record)
        XCTAssertEqual(paid.chargeCurrency, .cny, "美元可用的只有 2")
        summaries = try await backend.balanceSummaries()
        usd = try XCTUnwrap(summaries[account.id]?.item(.usd))
        XCTAssertEqual(usd.ledgerDerivedMinor, 10_00)
    }

    func testSingleCurrencyAccountStillResolvesYenSymbolByPreference() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427", currency: .usd)
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费¥30.00【招商银行】", source: .sms))
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.first?.record.currency, .cny, "账户不持有候选币种时按通知里的首选币种")
    }

    // MARK: 汇率

    func testExchangeRateFeedParsesAndConvertsWithMinorUnits() throws {
        let json = #"{"result":"success","base_code":"USD","time_last_update_unix":1792540800,"rates":{"USD":1,"CNY":7.2,"HKD":7.8,"JPY":150,"BAD":0}}"#
        let rates = try ExchangeRateFeed.parse(Data(json.utf8), fetchedAt: now)
        XCTAssertEqual(rates.base, .usd)
        XCTAssertEqual(rates.updatedAt, Date(timeIntervalSince1970: 1_792_540_800))
        XCTAssertNil(rates.rate(CurrencyCode("BAD")), "无效汇率被丢弃")
        XCTAssertEqual(rates.convert(100_00, from: .usd, to: .cny), 720_00)
        XCTAssertEqual(rates.convert(780_00, from: .hkd, to: .cny), 720_00)
        XCTAssertEqual(rates.convert(1_00, from: .usd, to: .jpy), 150, "日元没有小数位")
        XCTAssertEqual(rates.convert(-150, from: .jpy, to: .usd), -1_00)
        XCTAssertNil(rates.convert(1_00, from: CurrencyCode("XYZ"), to: .cny))
        XCTAssertEqual(rates.convert(1_23, from: CurrencyCode("XYZ"), to: CurrencyCode("XYZ")), 1_23)

        // 快捷指令把「URL 的内容」转成文本时，键的顺序、缩进和数字写法可能变化，还会带上其他字段
        let reformatted = """
        {
          "rates" : { "JPY" : 150, "CNY" : 7.2000000000000002, "USD" : 1.0 },
          "provider" : "https://www.exchangerate-api.com",
          "base_code" : "USD",
          "result" : "success"
        }
        """
        let fromShortcut = try ExchangeRateFeed.parse(Data(reformatted.utf8), fetchedAt: now)
        XCTAssertEqual(fromShortcut.updatedAt, now, "没有更新时间时用导入时间")
        XCTAssertEqual(fromShortcut.convert(100_00, from: .usd, to: .cny), 720_00)
        XCTAssertEqual(fromShortcut.convert(150, from: .jpy, to: .usd), 1_00)

        XCTAssertThrowsError(try ExchangeRateFeed.parse(Data(#"{"result":"error","error-type":"x"}"#.utf8), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateFeed.parse(Data("not json".utf8), fetchedAt: now))
    }

    func testCardInfoValidatesCardNumberAgainstLast4() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        try await backend.updateCardInfo(accountID: account.id, name: " 工资卡 ", cardNumber: "6225 8801 1234 0427")
        var stored = try await backend.accounts().first
        XCTAssertEqual(stored?.name, "工资卡")
        XCTAssertEqual(stored?.cardNumber, "6225880112340427", "去掉空格保存")

        for invalid in ["6225880112340428", "1234", "6225-8801-12a4-0427"] {
            do {
                try await backend.updateCardInfo(accountID: account.id, name: "工资卡", cardNumber: invalid)
                XCTFail("accepted \(invalid)")
            } catch {
                XCTAssertEqual(error as? BackendError, .invalidAccount(.invalidCardNumber))
            }
        }

        // 名称留空恢复默认名称；卡号留空清除
        try await backend.updateCardInfo(accountID: account.id, name: "", cardNumber: "")
        stored = try await backend.accounts().first
        XCTAssertEqual(stored?.name, "招商银行借记卡")
        XCTAssertNil(stored?.cardNumber)
    }

    func testCardFaceIsStoredAndTextScaleClamped() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        try await backend.updateCardFace(accountID: account.id, paletteID: "midnight", face: CardFace(imageID: "img", textColor: 0x112233, textScale: 5))
        let stored = try await backend.accounts().first
        XCTAssertEqual(stored?.paletteID, "midnight")
        XCTAssertEqual(stored?.face.imageID, "img")
        XCTAssertEqual(stored?.face.textColor, 0x112233)
        XCTAssertEqual(stored?.face.textScale, CardFace.textScaleRange.upperBound)
    }

    func testCardFaceAmountOutlineIsStoredAndPositionClamped() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        try await backend.updateCardFace(accountID: account.id, paletteID: "midnight", face: CardFace(imageID: "img", outlineColor: 0x445566, amountX: -0.5, amountY: 0.25))
        var stored = try await backend.accounts().first
        XCTAssertEqual(stored?.face.outlineColor, 0x445566)
        XCTAssertEqual(stored?.face.amountX, 0)
        XCTAssertEqual(stored?.face.amountY, 0.25)

        try await backend.updateCardFace(accountID: account.id, paletteID: "midnight", face: CardFace(imageID: "img", amountX: 0.5, amountY: 3))
        stored = try await backend.accounts().first
        XCTAssertNil(stored?.face.outlineColor)
        XCTAssertEqual(stored?.face.amountX, 0.5)
        XCTAssertEqual(stored?.face.amountY, 1)
    }

    func testReorderedAccountsKeepTheirOrderAndNewCardGoesLast() async throws {
        let backend = try makeBackend()
        let first = try await addAccount(backend, last4: "0001")
        let second = try await addAccount(backend, last4: "0002")
        let third = try await addAccount(backend, last4: "0003")
        try await backend.reorderAccounts([third.id, first.id, second.id])
        var ordered = try await backend.accounts().map(\.id)
        XCTAssertEqual(ordered, [third.id, first.id, second.id])

        let fourth = try await addAccount(backend, last4: "0004")
        ordered = try await backend.accounts().map(\.id)
        XCTAssertEqual(ordered, [third.id, first.id, second.id, fourth.id])
    }

    func testOpeningBalanceIsTheOnlyBase() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_000
        ))
        XCTAssertEqual(account.openingBalanceMinor, 100_000)
        XCTAssertEqual(account.openingBalanceAt, now)
        // 填写初始余额之前就到达的通知不重复计入
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日08:00消费20.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(-3600)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30消费10.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:40收入人民币50.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(120)))
        var summaries = try await backend.balanceSummaries()
        var summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.ledgerDerivedMinor, 104_000)
        XCTAssertEqual(summary.currency, .cny)
        XCTAssertEqual(summary.recordsAfterBase, 2)

        // 之后收到带余额的通知：通知里的余额不用，仍从初始余额推算
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日15:00消费5.00元，余额8,888.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(180)))
        summaries = try await backend.balanceSummaries()
        summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.ledgerDerivedMinor, 103_500)
        XCTAssertEqual(summary.recordsAfterBase, 3)
        XCTAssertEqual(summary.openingBalanceMinor, 100_000)
    }

    func testOpeningBalanceCanBeChangedAndCleared() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日09:00消费10.00元，余额900.00元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(-7200)))
        try await backend.setOpeningBalance(accountID: account.id, amountMinor: -50_000)
        var summaries = try await backend.balanceSummaries()
        var summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertEqual(summary.ledgerDerivedMinor, -50_000, "填写之前到达的流水不重复计入")

        try await backend.setOpeningBalance(accountID: account.id, amountMinor: nil)
        summaries = try await backend.balanceSummaries()
        summary = try XCTUnwrap(summaries[account.id]?.primary)
        XCTAssertNil(summary.ledgerDerivedMinor)
        XCTAssertNil(summary.openingBalanceMinor)

        do {
            try await backend.setOpeningBalance(accountID: "missing", amountMinor: 1)
            XCTFail("不存在的账户")
        } catch BackendError.notFound {}
    }

    func testMessageWithoutMoneyOrTailIsFilteredNotPending() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: "明天下午我要去银行办点事，晚点回你", source: .sms))
        XCTAssertEqual(result.classification, .noFinancialContent)
        XCTAssertEqual(result.outcome, .filtered)
        let pending = try await backend.pendingCount()
        XCTAssertEqual(pending, 0, "关键词误触发的普通短信不进待处理")
        let log = try await backend.ingestLog()
        XCTAssertTrue(log.isEmpty, "所有短信都会触发自动化：普通短信不保存，也不写接收日志")
    }

    func testMoneyMessageWithoutTailOrBankIsIgnored() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: "晚上的饭钱你转我100元就行", source: .sms))
        XCTAssertEqual(result.classification, .noFinancialContent)
        XCTAssertTrue(result.items.isEmpty)
        let pending = try await backend.pendingCount()
        XCTAssertEqual(pending, 0, "朋友的短信里有金额，但没有尾号、也不是银行发的，不进待处理")
    }

    // MARK: 不是动账的通知

    /// 尾号都不是自己的卡
    static let unrelatedMessages = [
        "【共享流量使用提醒】尊敬的（138****0011）客户，您好！截至10月31日12时14分，您的家庭共享主号（138****0012）本月可共享国内通用流量已用19.44GB，剩余4.85GB。信息仅供参考。其他流量使用情况可登录中国移动APP https://dx.10086.cn/A/abcDEF 查询。【中国移动】",
        "【顺丰速运】您尾号0011的手机有一个快件正在派送，快递员电话138****0012，请保持电话畅通。",
        "【滴滴出行】司机已接单，车牌尾号1234，约3分钟到达，请到路边等候。",
        "【某某政务】您尾号0011的手机号已完成实名认证。",
        "【中国移动】尊敬的138****0011客户，您本月已消费58.00元，账户余额12.30元。",
    ]

    func testUnrelatedMessagesAreDroppedAndNotStored() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0001")
        for text in Self.unrelatedMessages {
            let result = try await backend.ingest(IngestRequest(text: text, source: .auto))
            XCTAssertEqual(result.outcome, .filtered, text)
            XCTAssertNil(result.ingestID, text)
        }
        let pending = try await backend.pendingCount()
        XCTAssertEqual(pending, 0)
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
        let log = try await backend.ingestLog()
        XCTAssertTrue(log.isEmpty)
    }

    func testMaskedPhoneEqualToCardTailIsNotThatCard() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0011")
        let result = try await backend.ingest(IngestRequest(text: Self.unrelatedMessages[4], source: .auto))
        XCTAssertEqual(result.outcome, .filtered, "手机号后四位碰巧等于卡尾号：不能把话费记到这张卡上")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
    }

    func testNonBankSignatureWithOwnTailIsStillParsed() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "x", bankName: "某银行", last4: "0001")
        let result = try await backend.ingest(IngestRequest(text: "【某某商城】您尾号0001的卡于10月24日14:30消费人民币30.00元。", source: .auto))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
    }

    func testNonBankSignatureKeepsMessageWhenTemplateOrBoundAccountSaysSo() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "某银行", last4: "0001")
        let text = "【某某商城】您已付款人民币30.00元。"
        let bound = try await backend.ingest(IngestRequest(text: text, source: .auto, boundAccountID: account.id))
        XCTAssertEqual(bound.outcome, .pending, "绑定了账户：用户指定了要这里的通知")

        let sample = MessageParser.cleaned(text, source: .auto)
        let pieces = try MessageTemplates.build(sample: sample, amount: NSString(string: sample).range(of: "30.00"), cardTail: nil, counterparty: nil).get()
        _ = try await backend.saveTemplate(MessageTemplate(id: "t", name: "商城", pieces: pieces, kind: .purchase, direction: .outflow, createdAt: now))
        let result = try await backend.ingest(IngestRequest(text: "【某某商城】您已付款人民币31.00元。", source: .auto))
        XCTAssertNotEqual(result.outcome, .filtered, "用户做的模板优先，不按署名丢弃")
    }

    func testBankMessageWithoutAmountOrMatchingCardIsLoggedOnly() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0001")
        for text in ["【招商银行】您尾号0427的账户信息已更新。", "【宁波农商行】您尾号0427的账户信息已更新。"] {
            let result = try await backend.ingest(IngestRequest(text: text, source: .auto))
            XCTAssertEqual(result.outcome, .filtered, text)
            XCTAssertNotNil(result.ingestID, text)
        }
        let pending = try await backend.pendingCount()
        XCTAssertEqual(pending, 0)
        let log = try await backend.ingestLog()
        XCTAssertEqual(log.count, 2, "和不是动账的通知不同，留在接收日志")
        XCTAssertTrue(log.allSatisfy { $0.rawText != nil })
    }

    func testBankOrWalletMessageWithAmountButNoAccountIsPending() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0001")
        let bank = try await backend.ingest(IngestRequest(text: "【宁波农商行】您尾号0427的账户10月24日14:30消费人民币30.00元。", source: .auto))
        XCTAssertEqual(bank.outcome, .pending, "可能有卡没添加")
        let wallet = try await backend.ingest(IngestRequest(text: "【支付宝】你于10月24日12:30在某某咖啡消费25.00元。", source: .auto))
        XCTAssertEqual(wallet.outcome, .pending, "可能有钱包没添加")
    }

    func testAddedWalletNotificationIsParsed() async throws {
        let backend = try makeBackend()
        let alipay = try await backend.addAccount(.pocket(name: "支付宝余额", type: .wallet, currency: .cny, paletteID: "ocean", walletID: "alipay"))
        let result = try await backend.ingest(IngestRequest(text: "【支付宝】你于10月24日12:30在某某咖啡消费25.00元。", source: .auto))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let count = try await backend.recordCount(accountID: alipay.id)
        XCTAssertEqual(count, 1)
    }

    func testMessageWithUnknownTailAndNoSignatureOrTransactionIsDropped() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0001")
        let result = try await backend.ingest(IngestRequest(text: "您尾号0011的手机有一个快件正在派送", source: .auto))
        XCTAssertEqual(result.outcome, .filtered)
        XCTAssertNil(result.ingestID)
    }

    func testRealBankMessagesStillWork() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        let recorded = try await backend.ingest(IngestRequest(text: purchase, source: .auto))
        XCTAssertEqual(recorded.outcome, .recorded, recorded.summary)
        let otherCard = try await backend.ingest(IngestRequest(text: "您尾号9999账户10月24日14:40消费人民币20.00元", source: .auto))
        XCTAssertEqual(otherCard.outcome, .pending, "没有署名但交易完整（被截断的通知）：保持进待处理")
    }

    // MARK: 中行收入、招行预授权

    func testBOCIncomeRaisesBalance() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "boc", bankName: "中国银行", last4: "0001", cardType: .debit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_00
        ))
        _ = try await backend.ingest(IngestRequest(text: ParserSampleTests.bocIncome, source: .auto, receivedAt: now.addingTimeInterval(60)))
        let r = try await backend.records(accountID: account.id)[0].record
        XCTAssertEqual(r.direction, .inflow)
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[account.id]?.primary?.ledgerDerivedMinor, 188_00)
    }

    func testBOCIncomeWithoutCardIsPendingWithRightDirection() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: ParserSampleTests.bocIncome, source: .auto))
        XCTAssertEqual(result.outcome, .pending)
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .noMatchingAccount)
        XCTAssertEqual(item.draft?.direction, .inflow)
    }

    func testHoldThenCaptureBooksOnceAndClosesHold() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "0002", cardType: .credit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_00
        ))
        let hold = try await backend.ingest(IngestRequest(text: ParserSampleTests.cmbHold, source: .auto, receivedAt: now.addingTimeInterval(60)))
        XCTAssertEqual(hold.recordedCount, 1, hold.summary)
        var rows = try await backend.records(accountID: account.id)
        let held = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(held.status, .hold)
        XCTAssertEqual(held.amountMinor, 1000)
        XCTAssertEqual(held.currency, .jpy)
        XCTAssertEqual(held.chargeCurrency, .cny)
        XCTAssertEqual(held.settlementMinor, 48_00)
        var balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[account.id]?.primary?.ledgerDerivedMinor, 100_00, "冻结不动余额")

        let capture = try await backend.ingest(IngestRequest(text: ParserSampleTests.cmbCapture, source: .auto, receivedAt: now.addingTimeInterval(120)))
        XCTAssertEqual(capture.recordedCount, 1, capture.summary)
        balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[account.id]?.primary?.ledgerDerivedMinor, 52_00, "完成扣款只扣一次")
        rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.count, 2)
        let posted = try XCTUnwrap(rows.first { $0.record.status == .posted })
        let closed = try XCTUnwrap(rows.first { $0.record.id == held.id })
        XCTAssertEqual(closed.record.status, .holdReleased, "了结后不再是冻结")
        XCTAssertEqual(closed.record.relatedRecordID, posted.id)
        XCTAssertNil(closed.refundedMinor)
        let detail = try await backend.recordDetail(id: posted.id)
        XCTAssertTrue(detail.refunds.isEmpty, "了结的冻结不是退款")
        XCTAssertNil(posted.refundedMinor)
    }

    func testCaptureLeavesHoldAloneUnlessExactlyOneMatches() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0002", type: .credit)
        for hold in [
            "您尾号0002账户10月30日10:20在某某酒店预授权人民币100.00元【招商银行】",
            "您尾号0002账户10月30日10:20在某某民宿预授权人民币120.00元【招商银行】",
            "您尾号0002账户10月29日09:00在某某商店预授权人民币50.00元【招商银行】",
        ] {
            _ = try await backend.ingest(IngestRequest(text: hold, source: .auto))
        }

        // 两笔冻结都是这个时间：不猜是哪一笔
        _ = try await backend.ingest(IngestRequest(text: ParserSampleTests.cmbCapture, source: .auto))
        var rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.filter { $0.record.status == .hold }.count, 3)

        // 这个时间没有冻结：什么都不改
        let elsewhere = ParserSampleTests.cmbCapture.replacingOccurrences(of: "10月30日10:20", with: "10月28日08:00")
        _ = try await backend.ingest(IngestRequest(text: elsewhere, source: .auto))
        rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.filter { $0.record.status == .hold }.count, 3)
    }

    func testBracketedChargeFromMessageIsActualCharge() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "0002", cardType: .debit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_00
        ))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0002账户10月24日14:30消费JPY1000.00（人民币48.00）【招商银行】", source: .auto, receivedAt: now.addingTimeInterval(60)))
        let row = try await backend.records(accountID: account.id)[0]
        XCTAssertEqual(row.record.chargeCurrency, .cny)
        XCTAssertEqual(row.record.settlementMinor, 48_00)
        XCTAssertEqual(row.charge?.isActual, true)
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[account.id]?.primary?.ledgerDerivedMinor, 52_00, "按通知写的实际扣款，不按汇率估算")
    }

    /// 账户有这个币种：括号里的只是折合多少，扣的还是日元；日元不够、整笔换成人民币扣时，括号里的就是扣了多少
    func testBracketedChargeIsUsedOnlyWhenHeldCurrencyIsShort() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "0002", cardType: .debit, currency: .cny, paletteID: "ocean",
            openingBalanceMinor: 1_000_00, extraCurrencies: [.jpy], extraOpeningBalances: [.jpy: 5_000]
        ))
        _ = try await backend.ingest(IngestRequest(
            text: "您尾号0002账户10月24日14:30消费JPY1000.00（人民币48.00）【招商银行】", source: .auto, receivedAt: now.addingTimeInterval(60)
        ))
        var r = try await backend.records(accountID: account.id)[0].record
        XCTAssertEqual(r.currency, .jpy)
        XCTAssertNil(r.chargeCurrency)
        XCTAssertNil(r.settlementMinor)

        _ = try await backend.ingest(IngestRequest(
            text: "您尾号0002账户10月24日15:30消费JPY10000.00（人民币480.00）【招商银行】", source: .auto, receivedAt: now.addingTimeInterval(120)
        ))
        r = try await backend.records(accountID: account.id)[0].record
        XCTAssertEqual(r.amountMinor, 10_000)
        XCTAssertEqual(r.chargeCurrency, .cny, "日元只剩 4000")
        XCTAssertEqual(r.settlementMinor, 480_00)
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[account.id]?.item(.cny)?.ledgerDerivedMinor, 1_000_00 - 480_00)
        XCTAssertEqual(balances[account.id]?.item(.jpy)?.ledgerDerivedMinor, 4_000)
    }

    func testBalanceOnlyMessageCreatesNoRecord() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户截至10月24日16:00的可用余额为1,234.56元。【招商银行】", source: .sms))
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 0)
        let summary = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(summary?.ledgerDerivedMinor, 0, "只有余额的通知不改变卡片余额")
        let status = try await backend.automationStatus()
        XCTAssertEqual(status[account.id]?.lastSuccessAt, now, "但记为这张卡收到过自动输入")
    }

    // MARK: 繁体、英文、只靠尾号

    func testHangSengTraditionalChineseSmsIsRecorded() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd)
        let text = "【恒生銀行】恒生：你在16/03/2026透過結尾號碼0104的扣賬卡以「無卡支付」交易向WEIXIN*Sample mall Testcity CN支付了CNY37.15。如懷疑電28220228。"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let rows = try await backend.records(accountID: account.id)
        let r = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(r.amountMinor, 37_15)
        XCTAssertEqual(r.currency, .cny)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.counterparty, "WEIXIN*Sample mall Testcity CN")
    }

    /// 众安 ZA Card 消费邮件（脱敏）：尾号写在括号里「ZA Card (0106)」，金额单独一行，客服电话不是金额
    func testZACardPurchaseEmailIsRecorded() async throws {
        let backend = try makeBackend()
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "zabank", bankName: "众安银行", last4: "0106", cardType: .debit, currency: .hkd, paletteID: "ocean", extraCurrencies: [.cny]
        ))
        let text = """
        你好 Test,

        你于 2026-03-18 09:41:07 使用 ZA Card (0106) 完成一笔以下消费

        消费金额：
        HKD 8.25
        消费商户：DEMO SHOP TESTCITY L

        请到 ZA Bank App 了解详情，并查看 ZA Card 的回赠计划，让你下次消费可以赚取更多！

        如怀疑电 3665 3665。
        """
        let result = try await backend.ingest(IngestRequest(text: text, source: .auto))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let rows = try await backend.records(accountID: account.id)
        let r = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(r.amountMinor, 8_25)
        XCTAssertEqual(r.currency, .hkd)
        XCTAssertEqual(r.kind, .purchase)
    }

    /// 快捷指令「电子邮件」触发交来的是 HTML 正文：中英两段说的是同一笔，只记一笔
    func testHangSengCardNotPresentHtmlEmailIsRecorded() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd)
        let result = try await backend.ingest(IngestRequest(text: HangSengEmailSamples.cardNotPresent, source: .auto))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        XCTAssertEqual(result.recordedCount, 1)
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(r.amountMinor, 58_00)
        XCTAssertEqual(r.currency, .cny)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.counterparty, "54321 testcity CN")
        XCTAssertEqual(r.transactionTime?.day, 14)
        XCTAssertEqual(r.transactionTime?.month, 3)

        let weixin = try await backend.ingest(IngestRequest(text: HangSengEmailSamples.cardNotPresentWeixin, source: .auto))
        XCTAssertEqual(weixin.outcome, .recorded, weixin.summary)
        let latest = try await backend.records(accountID: account.id)
        let w = try XCTUnwrap(latest.first { $0.record.amountMinor == 7_00 }?.record, "金额没有小数：CNY7")
        XCTAssertEqual(w.currency, .cny)
        XCTAssertEqual(w.counterparty, "WEIXIN*Demo QR shop fo Testcity CN")
        XCTAssertEqual(latest.count, 2)

        // 同一封邮件再送一次（例如自动化跑了两次）不会重复记
        let again = try await backend.ingest(IngestRequest(text: HangSengEmailSamples.cardNotPresent, source: .auto))
        XCTAssertNotEqual(again.outcome, .recorded, again.summary)
        let count = try await backend.recordCount(accountID: account.id)
        XCTAssertEqual(count, 2)
    }

    /// 恒生转账邮件（脱敏）：只写打码的户口号码，不写卡号尾号；中英双语；金额单独一行。
    static let hangSengTransferEmail = """

        如未能正常顯示電郵內容，請你設定電郵瀏覽程式至支援HTML格式的電郵。
        If you cannot view this email properly, please configure your email programme so that it can support HTML formatted emails.


        你已成功轉賬
        Your transfer is successful


        由 From
        123-456XXX-789



        HKD275.40


        至 To
        +86-1380000****


        交易狀況
        Transfer status

        已成功轉賬至收款人
        Successfully transferred to payee

        轉賬日期
        Transfer date

        2026-03-16

        收款銀行
        Receiving bank

        眾安銀行有限公司
        ZA Bank Limited

        預設銀行
        Default bank

        N

        交易號碼
        Transaction ID

        HD000A0000000001

        參考編號
        Reference number

        NA0000000001


        多謝選用我們的服務
        Thank you for using our service

        如你本人並沒有發出此指示或有任何疑問，請即通知我們，我們將為你跟進。
        If this is not you, or if you have any doubts towards this instruction, please contact us as soon as possible. We will help you out.

        2822 0228

        你亦可透過恒生Mobile App內的在線通訊與我們聯絡。
        You may also contact us by the Live Chat function in Hang Seng Mobile App.

        這是電腦編印的電郵，無須簽署。請勿回覆此電郵。本電郵的中英文文本如有歧義，概以英文本為準。

        如你的聯絡資料有所變更，請使用保安編碼器或流動保安編碼登入桌面版恒生個人e-Banking或恒生Mobile App更新，或於恒生銀行網站下載更改客戶資料表格，填妥表格後交回我們任何一間分行或郵寄到香港郵政信箱3013號恒生銀行有限公司。

        保安提示: 恒生銀行採納高度安全標準及程序以防止客戶之資料未經授權而外洩。我們不會以電郵聯絡你，而要求你核實個人資料，例如使用者名稱、戶口號碼或密碼等資料。如你收到此等要求，可聯絡我們。

        ©恒生銀行有限公司2026。版權所有，不得轉載。
        ©Hang Seng Bank Limited 2026. All rights reserved.

        香港德輔道中83號
        83 Des Voeux Road Central Hong Kong
        """

    func testHangSengTransferEmailMatchesByAccountNumber() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd)
        // 没填账号时对不上卡：进待处理，可以选卡
        let before = try await backend.ingest(IngestRequest(text: Self.hangSengTransferEmail, source: .auto))
        XCTAssertEqual(before.outcome, .pending, before.summary)
        XCTAssertEqual(before.items.first?.kind, .transferOut)
        XCTAssertEqual(before.items.first?.amountText, "275.40")

        // 卡片信息里粘贴打码的账号后，同类邮件直接记到这张卡
        try await backend.updateAccountNumber(accountID: account.id, accountNumber: "123-456xxx-789")
        let stored = try await backend.accounts().first { $0.id == account.id }
        XCTAssertEqual(stored?.accountNumber, "123-456XXX-789")
        let text = Self.hangSengTransferEmail.replacingOccurrences(of: "HKD275.40", with: "HKD100.00").replacingOccurrences(of: "HD000A0000000001", with: "HD000A0000000002")
        let after = try await backend.ingest(IngestRequest(text: text, source: .auto))
        XCTAssertEqual(after.outcome, .recorded, after.summary)
        let rows = try await backend.records(accountID: account.id)
        let r = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(r.amountMinor, 100_00)
        XCTAssertEqual(r.currency, .hkd)
        XCTAssertEqual(r.direction, .outflow)
        XCTAssertEqual(r.kind, .transferOut)
        XCTAssertTrue(r.needsTransferConfirmation, "没配对到自己另一张卡：问是不是转给自己的账户")

        do {
            try await backend.updateAccountNumber(accountID: account.id, accountNumber: "abc")
            XCTFail("账号只能是数字、X 和短横线")
        } catch BackendError.invalidAccount(.invalidAccountNumber) {}
    }

    func testTruncatedNotificationStillUsable() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd)
        // App 通知被发送方截断：后半段（日期、交易号码、银行名称）没有了
        let text = """
        Test
        如未能正常顯示電郵內容，請你設定電郵瀏覽程式至支援HTML格式的電郵。
        If you cannot view this email properly, please configure your email programme so that it can support HTML formatted emails.
        你已成功轉賬
        Your transfer is successful
        由 From
        123-456XXX-789
        HKD275.40

        至 To
        +86-1380000***...
        """
        // 没填账号：认不出卡，但交易完整，进待处理而不是被当成普通通知丢掉
        let before = try await backend.ingest(IngestRequest(text: text, source: .auto))
        XCTAssertEqual(before.outcome, .pending, before.summary)

        try await backend.updateAccountNumber(accountID: account.id, accountNumber: "123-456XXX-789")
        let after = try await backend.ingest(IngestRequest(text: text + " ", source: .notification))
        XCTAssertNotEqual(after.outcome, .filtered, after.summary)
        XCTAssertEqual(after.items.first?.cardTail, "0104")
        XCTAssertEqual(after.items.first?.kind, .transferOut)
    }

    func testMaskedNumbersMatchAccountNumberOrCardNumber() {
        let account = Account(
            id: "a", name: "", bankID: nil, bankName: "恒生银行", last4: "0104", cardType: .debit, currency: .hkd,
            paletteID: "ocean", sortOrder: 0, createdAt: now, cardNumber: "4000123412340104", accountNumber: "100-200123-300"
        )
        XCTAssertEqual(IngestEngine.identifierTail(in: "由 From 100-200XXX-300 转账", accounts: [account]), "0104")
        XCTAssertEqual(IngestEngine.identifierTail(in: "a/c ******300 debited", accounts: [account]), "0104", "只露出末几位时和号码末尾比较")
        XCTAssertEqual(IngestEngine.identifierTail(in: "card 4000-12XX-XXXX-0104", accounts: [account]), "0104")
        XCTAssertNil(IngestEngine.identifierTail(in: "由 From 100-200XXX-301 转账", accounts: [account]))
        XCTAssertNil(IngestEngine.identifierTail(in: "电话 2822 0228", accounts: [account]))
        XCTAssertEqual(Account.normalizedAccountNumber(" 100-200*** -300 "), "100-200XXX-300")
        XCTAssertNil(Account.normalizedAccountNumber("XXX-XXX"), "至少 3 位数字")
    }

    func testTransferToUntrackedAccountCanBeMarkedOwn() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日14:30向张三转账500.00元【招商银行】", source: .sms))
        var unconfirmed = try await backend.unconfirmedTransfers()
        XCTAssertEqual(unconfirmed.count, 1)
        var stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor, 500_00, "确认之前按转给别人统计")

        try await backend.setTransferParty(recordID: unconfirmed[0].id, party: .own)
        stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor, 0, "转给自己的账户不算支出")
        XCTAssertEqual(stats.currencies.first?.internalTransferMinor, 500_00)
        unconfirmed = try await backend.unconfirmedTransfers()
        XCTAssertTrue(unconfirmed.isEmpty)
        let count = try await backend.unconfirmedTransferCount()
        XCTAssertEqual(count, 0)

        let rows = try await backend.records(accountID: account.id)
        try await backend.setTransferParty(recordID: try XCTUnwrap(rows.first?.id), party: .other)
        stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.expenseMinor, 500_00)
    }

    func testKnownCardTailIsFoundWithoutFixedWording() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "Example Bank", last4: "5521", currency: .usd)
        try await addAccount(backend, bank: "y", bankName: "Other Bank", last4: "2026", currency: .usd)
        // 「card 5521」不是解析器认识的尾号写法；日期里的 2026 不算尾号
        let result = try await backend.ingest(IngestRequest(text: "Example Bank: card 5521 spent USD 12.00 at AMAZON on 24 Oct 2026", source: .sms))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.first?.record.amountMinor, 12_00)

        XCTAssertNil(IngestEngine.knownTail(in: "支付了CNY5521", accounts: [account]), "金额不算尾号")
        XCTAssertNil(IngestEngine.knownTail(in: "电话 2855210000", accounts: [account]), "长数字的一部分不算尾号")
        XCTAssertEqual(IngestEngine.knownTail(in: "a/c XX5521 debited", accounts: [account]), "5521")
    }

    func testNoTailGoesToTheOnlyCardOfThatBank() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0001")
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "0002")
        let result = try await backend.ingest(IngestRequest(text: "【招商银行】您的账户10月24日消费20.00元", source: .sms))
        XCTAssertEqual(result.outcome, .recorded, result.summary)
        let count = try await backend.recordCount(accountID: account.id)
        XCTAssertEqual(count, 1)
    }

    func testNoTailAmongSeveralCardsOfThatBankAsksWhichOne() async throws {
        let backend = try makeBackend()
        let first = try await addAccount(backend, last4: "0001")
        let second = try await addAccount(backend, last4: "0002")
        _ = try await backend.ingest(IngestRequest(text: "【招商银行】您的账户10月24日消费20.00元", source: .sms))
        let items = try await backend.openPendingItems()
        XCTAssertEqual(items.first?.reason, .ambiguousAccount)
        XCTAssertEqual(items.first.map { Set($0.candidateAccountIDs) }, [first.id, second.id])
    }

    func testBankOutsideTheDirectoryIsFoundBySignature() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "hangseng", bankName: "恒生银行", last4: "0001", currency: .hkd)
        let za = try await addAccount(backend, bank: "zabank", bankName: "众安银行", last4: "0002", currency: .hkd)
        _ = try await backend.ingest(IngestRequest(text: ParserSampleTests.phoneTransfer, source: .sms))
        let count = try await backend.recordCount(accountID: za.id)
        XCTAssertEqual(count, 1)
    }

    func testNoTailIsRecordedOnceTheBanksCardIsAdded() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "0001")
        _ = try await backend.ingest(IngestRequest(text: ParserSampleTests.phoneTransfer, source: .sms))
        let before = try await backend.pendingCount()
        XCTAssertEqual(before, 1)
        let za = try await addAccount(backend, bank: "zabank", bankName: "众安银行", last4: "0002", currency: .hkd)
        let after = try await backend.pendingCount()
        XCTAssertEqual(after, 0)
        let count = try await backend.recordCount(accountID: za.id)
        XCTAssertEqual(count, 1)
    }

    func testTwoFeesInOneSentenceAreBothKept() async throws {
        let backend = try makeBackend()
        let result = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0001账户10月24日消费100.00元，手续费1.00元，服务费2.00元", source: .sms))
        XCTAssertEqual(result.pendingCount, 3, result.summary)
    }

    func testEitherAccountOrCardNumberCanBeTheAddedOne() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "Example Bank", last4: "0001", currency: .usd)
        let text = "Example Bank\nDebit Card Purchase\nAccount XXXX0001\nCard XXXX0002\nUSD 20.00\nTEST SHOP"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.count, 1)
    }

    func testWalletAddedAsCardReceivesNoTailNotices() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, bank: "maya", bankName: "Maya", last4: "0007", currency: CurrencyCode("PHP"))
        let result = try await backend.ingest(IngestRequest(text: "Sent PHP 200.00 to 0917***0000. Ref no. 123456789012", source: .sms, sender: "Maya"))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.first?.record.kind, .transferOut)
    }

    func testAccountNamedInTheTextIsKeptAsACandidate() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, bank: "maya", bankName: "Maya", last4: "0007", currency: CurrencyCode("PHP"))
        let result = try await backend.ingest(IngestRequest(text: "Sent PHP 200.00 to 0917***0000 via Maya. Ref no. 123456789012", source: .sms))
        XCTAssertEqual(result.pendingCount, 1, "没有发件人和署名，只是提到名称：不直接入账，也不丢掉")
        let items = try await backend.openPendingItems()
        XCTAssertEqual(items.first?.candidateAccountIDs, [card.id])
    }

    func testFormalAmountFromUnknownSenderIsKept() async throws {
        let backend = try makeBackend()
        let kept = try await backend.ingest(IngestRequest(text: "Cash in of PHP 1,000.00 to your wallet is successful.", source: .sms))
        XCTAssertEqual(kept.pendingCount, 1, kept.summary)
        let chat = try await backend.ingest(IngestRequest(text: "晚上吃饭AA，你转我100元就行", source: .sms))
        XCTAssertEqual(chat.outcome, .filtered)
    }

    func testThreeDigitTailMatchesTheEndOfTheCard() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, bank: "psbc", bankName: "中国邮政储蓄银行", last4: "0017")
        let result = try await backend.ingest(IngestRequest(text: "【邮储银行】26年11月01日10:20您尾号017账户提现，金额100.00元，余额500.00元。", source: .sms))
        XCTAssertEqual(result.recordedCount, 1, result.summary)
        let rows = try await backend.records(accountID: card.id)
        XCTAssertEqual(rows.first?.record.kind, .withdrawal)
    }

    func testPendingWithoutTailCanBeAssignedToAnyCard() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: "您的账户10月24日消费20.00元", source: .sms))
        let item = try await backend.openPendingItems()[0]
        XCTAssertEqual(item.reason, .missingCardTail)
        XCTAssertTrue(item.candidateAccountIDs.isEmpty)
        try await backend.confirmPending(id: item.id, accountID: account.id)
        let count = try await backend.recordCount(accountID: account.id)
        XCTAssertEqual(count, 1)
    }

    // MARK: 内部转账、还款、退款

    func testInternalTransferBetweenOwnCardsIsLinkedAndExcludedFromStats() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】", source: .sms, sender: "95555"))
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】", source: .sms, sender: "95588"))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2, "两边流水都保留")
        XCTAssertEqual(Set(rows.map(\.record.accountID)), [a.id, b.id])
        XCTAssertNotNil(rows[0].record.transferGroupID)
        XCTAssertEqual(rows[0].record.transferGroupID, rows[1].record.transferGroupID)
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 0)
        XCTAssertEqual(cny.incomeMinor, 0)
        XCTAssertEqual(cny.internalTransferMinor, 100_000)
    }

    func testCreditCardRepaymentFromOwnDebitIsNotDoubleCounted() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月10日消费3,000.00元。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月20日10:00还款3,000.00元，余额734.56元【招商银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡于10月20日还款成功，金额3,000.00元已入账。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 3)
        let repayments = rows.filter { $0.record.kind == .repayment }
        XCTAssertEqual(Set(repayments.map(\.record.direction)), [.inflow, .outflow])
        let stats = try await backend.monthStats(year: 2026, month: 10)
        let cny = try XCTUnwrap(stats.currencies.first)
        XCTAssertEqual(cny.expenseMinor, 300_000, "只有信用卡消费计入支出，还款不再重复计为支出")
        XCTAssertEqual(cny.incomeMinor, 0)
    }

    func testRefundKeepsOriginalAndLinks() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "boc", bankName: "中国银行", last4: "8810", type: .credit)
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡10月20日消费人民币99.00元，商户：京东商城。【中国银行】", source: .sms))
        _ = try await backend.ingest(IngestRequest(text: "您尾号8810的信用卡收到退款人民币99.00元，商户：京东商城。【中国银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2, "退款不覆盖、不删除原交易")
        let refund = try XCTUnwrap(rows.first { $0.record.kind == .refund })
        let original = try XCTUnwrap(rows.first { $0.record.kind == .purchase })
        XCTAssertEqual(refund.record.relatedRecordID, original.id)
        let stats = try await backend.monthStats(year: 2026, month: 10)
        XCTAssertEqual(stats.currencies.first?.netExpenseMinor, 0)
    }

    func testIncludedFeeSplitSumsToTotal() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621卡10月24日支出1,002.00元(含手续费2.00元)，摘要：跨行汇款，余额998.00元。【工商银行】", source: .sms))
        let rows = try await backend.records()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.record.amountMinor).reduce(0, +), 100_200)
        XCTAssertEqual(Set(rows.map(\.record.kind)), [.transferOut, .fee])
    }

    // MARK: 备注与保留期限

    func testUpdateNoteChangesOnlyTheNote() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        let before = try await backend.records()[0].record
        try await backend.updateNote(recordID: before.id, note: "和同事喝咖啡")
        let after = try await backend.records()[0].record
        XCTAssertEqual(after.note, "和同事喝咖啡")
        var expected = before
        expected.note = "和同事喝咖啡"
        XCTAssertEqual(after, expected, "其他字段保持不变")
    }

    func testRawContentPurgedAfterRetentionButFingerprintKept() async throws {
        var current = now
        let database = try Database.inMemory()
        let clockBox = ClockBox(now)
        let backend = LedgerBackend(database: database, calendar: calendar, clock: { clockBox.value })
        try await addAccount(backend, last4: "0427")
        try await backend.setRawRetentionDays(7)
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        current = current.addingTimeInterval(8 * 86_400)
        clockBox.value = current
        let purged = try await backend.purgeExpiredRawContent()
        XCTAssertEqual(purged, 1)
        let log = try await backend.ingestLog()
        XCTAssertNil(log[0].rawText)
        let again = try await backend.ingest(IngestRequest(text: purchase, source: .sms))
        XCTAssertEqual(again.outcome, .duplicateInput, "清理正文后仍能识别重复输入")
    }

    func testAddAccountValidation() async throws {
        let backend = try makeBackend()
        do {
            _ = try await addAccount(backend, last4: "12a4")
            XCTFail()
        } catch BackendError.invalidAccount(.invalidLast4) {}
        try await addAccount(backend, last4: "0001")
        do {
            _ = try await addAccount(backend, last4: "0001")
            XCTFail()
        } catch BackendError.invalidAccount(.duplicateAccount) {}
        let accounts = try await backend.accounts()
        XCTAssertEqual(accounts.map(\.last4), ["0001"])
    }

    func testPaginationIsStable() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, last4: "0427")
        for minute in 0..<7 {
            _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日10:0\(minute)消费1.0\(minute)元【招商银行】", source: .sms, receivedAt: now.addingTimeInterval(Double(minute) * 60)))
        }
        var cursor: RecordCursor?
        var seen: [String] = []
        repeat {
            let page = try await backend.records(before: cursor, limit: 3)
            seen += page.map(\.id)
            cursor = page.last.map { RecordCursor(effectiveAt: $0.record.effectiveAt, id: $0.id) }
            if page.count < 3 { break }
        } while true
        XCTAssertEqual(seen.count, 7)
        XCTAssertEqual(Set(seen).count, 7)
    }

    // MARK: 金额有歧义、电话号码

    func testPhoneNumberTransferWithoutTailIsOneRecord() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "众安银行", last4: "5566", currency: .hkd)
        let result = try await backend.ingest(IngestRequest(text: ParserSampleTests.phoneTransfer, source: .sms))
        XCTAssertEqual(result.recordedCount, 1, "手机号里的数字不再各算一笔：\(result.summary)")
        let rows = try await backend.records(accountID: account.id)
        let r = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(r.amountMinor, 23_75)
        XCTAssertEqual(r.currency, .hkd)
        XCTAssertEqual(r.kind, .transferOut)
        XCTAssertEqual(r.counterparty, "+86-138******00")
    }

    func testChoosingOneOfAmbiguousAmountsIgnoresTheOthers() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427")
        let result = try await backend.ingest(IngestRequest(text: "【招商银行】您尾号0427的账户10月24日12:00消费100.00元，实际扣款95.00元。", source: .sms, sender: "95555"))
        XCTAssertEqual(result.pendingCount, 2, result.summary)
        let items = try await backend.openPendingItems()
        XCTAssertEqual(Set(items.map(\.reason)), [.ambiguousAmount])
        let chosen = try XCTUnwrap(items.first { $0.draft?.amount.digits == "95.00" })
        try await backend.confirmPending(id: chosen.id, accountID: account.id)
        let rows = try await backend.records(accountID: account.id)
        XCTAssertEqual(rows.map(\.record.amountMinor), [95_00])
        let open = try await backend.pendingCount()
        XCTAssertEqual(open, 0, "同一条通知里的其他候选金额自动忽略")
    }
}

final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
