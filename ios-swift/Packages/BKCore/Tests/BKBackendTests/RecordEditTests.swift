import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 流水的修改、删除、查找；外币交易按主币种扣款；卡片信息修改；银行和币种列表。
final class RecordEditTests: XCTestCase {
    var calendar: Calendar { ParserSampleTests.calendar }
    /// 2026-10-24 16:00 +08:00
    let now = ParserSampleTests.reference
    let purchase = "【招商银行】您尾号0427的储蓄卡于10月24日14:30在星巴克咖啡消费人民币38.00元，余额1,234.56元。"

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: { now })
    }

    @discardableResult
    func addAccount(
        _ backend: LedgerBackend, bank: String = "cmb", bankName: String = "招商银行", last4: String, type: CardType = .debit,
        currency: CurrencyCode = .cny, extras: [CurrencyCode] = [], opening: Int64? = nil
    ) async throws -> Account {
        try await backend.addAccount(AccountDraft(
            name: "", bankID: bank, bankName: bankName, last4: last4, cardType: type, currency: currency, paletteID: "ocean",
            openingBalanceMinor: opening, extraCurrencies: extras
        ))
    }

    /// 1 美元 = 7.8 港币 = 7.2 人民币（可改）
    func rates(_ updatedAt: Date, cny: Double = 7.2) -> ExchangeRates {
        ExchangeRates(base: .usd, rates: ["USD": 1, "HKD": 7.8, "CNY": cny], updatedAt: updatedAt, fetchedAt: updatedAt)
    }

    func firstRow(_ backend: LedgerBackend, accountID: String? = nil) async throws -> RecordRow {
        let rows = try await backend.records(accountID: accountID)
        return try XCTUnwrap(rows.first)
    }

    // MARK: 外币交易按主币种扣款

    func testForeignCurrencyIsChargedToPrimaryAtTransactionDayRate() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd, opening: 1_000_00)
        try await backend.saveExchangeRates(rates(now.addingTimeInterval(-86_400), cny: 7.0))
        try await backend.saveExchangeRates(rates(now))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0104的账户于10月24日14:30消费人民币72.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))

        let row = try await firstRow(backend, accountID: account.id)
        XCTAssertEqual(row.record.currency, .cny)
        XCTAssertTrue(row.isForeignCurrency)
        XCTAssertEqual(row.charge?.currency, .hkd)
        XCTAssertEqual(row.charge?.amountMinor, 78_00, "72 人民币 ÷ 7.2 × 7.8 = 78 港币")
        XCTAssertEqual(row.charge?.rateDay, "2026-10-24", "用交易当天的汇率")
        XCTAssertEqual(row.charge?.isActual, false)
        var balance = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(balance?.ledgerDerivedMinor, 1_000_00 - 78_00)

        // 用户按银行账单改成实际扣款
        try await backend.updateRecord(id: row.id, RecordEdit(
            accountID: account.id, amountMinor: 72_00, currency: .cny, direction: .outflow, kind: .purchase,
            counterparty: nil, time: nil, note: "", settlementMinor: 79_10
        ))
        let corrected = try await firstRow(backend, accountID: account.id)
        XCTAssertEqual(corrected.charge?.amountMinor, 79_10)
        XCTAssertEqual(corrected.charge?.isActual, true)
        balance = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(balance?.ledgerDerivedMinor, 1_000_00 - 79_10)
        let byCharge = try await backend.records(filter: RecordFilter(text: "79.1"))
        XCTAssertEqual(byCharge.map(\.id), [row.id], "按实际扣了多少港币也能找到")

        // 卡里加上人民币以后，这笔记在人民币里，不再扣港币
        try await backend.updateAccount(id: account.id, AccountEdit(
            name: "", cardType: .debit, currency: .hkd, extraCurrencies: [.cny], cardNumber: nil, accountNumber: nil
        ))
        let held = try await firstRow(backend, accountID: account.id)
        XCTAssertFalse(held.isForeignCurrency)
        XCTAssertNil(held.charge)
        balance = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(balance?.ledgerDerivedMinor, 1_000_00)
    }

    func testRateDayFallsBackToRecordedDayThenNearest() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd)
        try await backend.saveExchangeRates(rates(now))
        try await backend.saveExchangeRates(rates(now.addingTimeInterval(-6 * 86_400), cny: 6.0))
        // 交易在 10 月 20 日，那天没有汇率；App 在 24 日处理：用 24 日的，不用更近的 18 日
        _ = try await backend.ingest(IngestRequest(text: "您尾号0104的账户于10月20日09:00消费人民币72.00元【恒生银行】", source: .sms, receivedAt: now))
        let row = try await firstRow(backend, accountID: account.id)
        XCTAssertEqual(row.charge?.rateDay, "2026-10-24")
        XCTAssertEqual(row.charge?.amountMinor, 78_00)

        let days = ["2026-10-18", "2026-10-24"]
        XCTAssertEqual(ChargeCalculator.nearest(days, to: "2026-10-20"), "2026-10-18")
        XCTAssertEqual(ChargeCalculator.nearest(days, to: "2026-10-22"), "2026-10-24")
        XCTAssertEqual(ChargeCalculator.nearest(days, to: "2026-10-21"), "2026-10-18", "一样近取更早的")
        XCTAssertEqual(ChargeCalculator.nearest(days, to: "2026-11-30"), "2026-10-24")
        XCTAssertEqual(ChargeCalculator.nearest(days, to: "2026-01-01"), "2026-10-18")
        XCTAssertNil(ChargeCalculator.nearest([], to: "2026-01-01"))
        XCTAssertTrue(ChargeCalculator.contains(days, "2026-10-24"))
        XCTAssertFalse(ChargeCalculator.contains(days, "2026-10-23"))
        XCTAssertEqual(ChargeCalculator.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(try XCTUnwrap(ChargeCalculator.dayNumber("2024-03-01")) - (try XCTUnwrap(ChargeCalculator.dayNumber("2024-02-28"))), 2, "闰年")
        XCTAssertEqual(try XCTUnwrap(ChargeCalculator.dayNumber("2026-03-01")) - (try XCTUnwrap(ChargeCalculator.dayNumber("2026-02-28"))), 1)
    }

    func testForeignCurrencyWithoutAnyRateIsLeftOutOfBalance() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0104", currency: .hkd, opening: 1_000_00)
        _ = try await backend.ingest(IngestRequest(text: "您尾号0104的账户于10月24日14:30消费人民币72.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        let row = try await firstRow(backend, accountID: account.id)
        XCTAssertNotNil(row.charge)
        XCTAssertNil(row.charge?.amountMinor, "还没有任何汇率")
        let balance = try await backend.balanceSummaries()[account.id]?.primary
        XCTAssertEqual(balance?.ledgerDerivedMinor, 1_000_00)
        XCTAssertEqual(balance?.unconvertedCount, 1)
    }

    // MARK: 修改、删除

    func testRecordCanBeEditedAndMovedToAnotherCard() async throws {
        let backend = try makeBackend()
        let a = try await addAccount(backend, last4: "0427", opening: 500_00)
        let b = try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621", opening: 100_00)
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms, receivedAt: now.addingTimeInterval(60)))
        let original = try await firstRow(backend).record
        XCTAssertEqual(original.accountID, a.id)

        let later = now.addingTimeInterval(3600)
        try await backend.updateRecord(id: original.id, RecordEdit(
            accountID: b.id, amountMinor: 40_00, currency: .cny, direction: .outflow, kind: .purchase,
            counterparty: "  瑞幸  ", time: later, note: "改过"
        ))
        let edited = try await firstRow(backend).record
        XCTAssertEqual(edited.accountID, b.id)
        XCTAssertEqual(edited.amountMinor, 40_00)
        XCTAssertEqual(edited.counterparty, "瑞幸")
        XCTAssertEqual(edited.note, "改过")
        XCTAssertEqual(edited.receivedAt, later)
        XCTAssertEqual(edited.transactionTime?.hour, 17)
        XCTAssertEqual(edited.transactionTime?.day, 24)
        XCTAssertEqual(edited.source, original.source, "来源不变")
        XCTAssertEqual(edited.ingestID, original.ingestID)
        let balances = try await backend.balanceSummaries()
        XCTAssertEqual(balances[a.id]?.primary?.ledgerDerivedMinor, 500_00)
        XCTAssertEqual(balances[b.id]?.primary?.ledgerDerivedMinor, 100_00 - 40_00)

        // 没改时间：时间保持原样
        try await backend.updateRecord(id: original.id, RecordEdit(
            accountID: b.id, amountMinor: 40_00, currency: .cny, direction: .inflow, kind: .refund, counterparty: nil, time: nil, note: ""
        ))
        let again = try await firstRow(backend).record
        XCTAssertEqual(again.receivedAt, later)
        XCTAssertEqual(again.direction, .inflow)
        XCTAssertNil(again.counterparty)

        do {
            try await backend.updateRecord(id: original.id, RecordEdit(
                accountID: b.id, amountMinor: 0, currency: .cny, direction: .outflow, kind: .purchase, counterparty: nil, time: nil, note: ""
            ))
            XCTFail("金额必须大于 0")
        } catch BackendError.invalidAmount {}
    }

    func testDeletingOneSideOfInternalTransferUnpairsTheOther() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        let transferOut = "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】"
        _ = try await backend.ingest(IngestRequest(text: transferOut, source: .sms, sender: "95555"))
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】", source: .sms, sender: "95588"))
        var rows = try await backend.records()
        XCTAssertNotNil(rows[0].record.transferGroupID)
        let outflow = try XCTUnwrap(rows.first { $0.record.direction == .outflow }).record

        try await backend.deleteRecord(id: outflow.id)
        rows = try await backend.records()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].record.transferGroupID, "只剩一边，不再算内部转账")

        let repeated = try await backend.ingest(IngestRequest(text: transferOut, source: .sms, sender: "95555"))
        XCTAssertEqual(repeated.outcome, .duplicateInput, "同一条通知再来不会重新记上")
        let count = try await backend.recordCount()
        XCTAssertEqual(count, 1)
        do {
            try await backend.deleteRecord(id: outflow.id)
            XCTFail()
        } catch BackendError.notFound {}
    }

    func testChangingAmountOfInternalTransferUnpairsIt() async throws {
        let backend = try makeBackend()
        try await addAccount(backend, bank: "cmb", bankName: "招商银行", last4: "0427")
        try await addAccount(backend, bank: "icbc", bankName: "工商银行", last4: "6621")
        _ = try await backend.ingest(IngestRequest(text: "您尾号0427账户10月24日10:00转出1,000.00元，余额200.00元【招商银行】", source: .sms, sender: "95555"))
        _ = try await backend.ingest(IngestRequest(text: "您尾号6621账户10月24日10:01转入1,000.00元，余额3,000.00元【工商银行】", source: .sms, sender: "95588"))
        let paired = try await backend.records()
        let outflow = try XCTUnwrap(paired.first { $0.record.direction == .outflow }).record
        // 只改备注：仍然配对
        try await backend.updateRecord(id: outflow.id, RecordEdit(
            accountID: outflow.accountID, amountMinor: outflow.amountMinor, currency: .cny, direction: .outflow, kind: outflow.kind,
            counterparty: outflow.counterparty, time: nil, note: "房租"
        ))
        let stillPaired = try await backend.records()
        XCTAssertTrue(stillPaired.allSatisfy { $0.record.transferGroupID != nil })
        try await backend.updateRecord(id: outflow.id, RecordEdit(
            accountID: outflow.accountID, amountMinor: 900_00, currency: .cny, direction: .outflow, kind: outflow.kind,
            counterparty: outflow.counterparty, time: nil, note: "房租"
        ))
        let unpaired = try await backend.records()
        XCTAssertTrue(unpaired.allSatisfy { $0.record.transferGroupID == nil })
    }

    // MARK: 查找

    func testFilterByCurrencyTextDirectionAndPeriod() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, bank: "x", bankName: "恒生银行", last4: "0105", currency: .hkd, extras: [.usd])
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日14:30消费美元12.50元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(60)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日15:30消费港币100.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(120)))
        _ = try await backend.ingest(IngestRequest(text: "您尾号0105的账户于10月24日16:30消费人民币30.00元【恒生银行】", source: .sms, receivedAt: now.addingTimeInterval(180)))

        let usd = try await backend.records(filter: RecordFilter(accountID: account.id, currency: .usd))
        XCTAssertEqual(usd.map(\.record.currency), [.usd])
        let hkd = try await backend.records(filter: RecordFilter(accountID: account.id, currency: .hkd))
        XCTAssertEqual(hkd.map(\.record.currency), [.cny, .hkd], "主币种也包括卡里没有的币种")
        let hkdCount = try await backend.recordCount(filter: RecordFilter(accountID: account.id, currency: .hkd))
        XCTAssertEqual(hkdCount, 2)

        let byAmount = try await backend.records(filter: RecordFilter(text: "12.5"))
        XCTAssertEqual(byAmount.map(\.record.amountMinor), [12_50])
        let byWholeAmount = try await backend.records(filter: RecordFilter(text: "100"))
        XCTAssertEqual(byWholeAmount.map(\.record.amountMinor), [100_00])
        let roughly = try await backend.records(filter: RecordFilter(text: "12"))
        XCTAssertEqual(roughly.map(\.record.amountMinor), [12_50], "只写整数：差不多的金额也算（12 找 10.80～13.20）")
        let roughlyLower = try await backend.records(filter: RecordFilter(text: "28"))
        XCTAssertEqual(roughlyLower.map(\.record.amountMinor), [30_00], "28 找 25.20～30.80")
        let tooFar = try await backend.records(filter: RecordFilter(text: "35"))
        XCTAssertTrue(tooFar.isEmpty, "35 找 31.50～38.50，30 不算")
        let exactCents = try await backend.records(filter: RecordFilter(text: "12.4"))
        XCTAssertTrue(exactCents.isEmpty, "写了小数的按原样找")
        let byTailAndKind = try await backend.records(filter: RecordFilter(text: "0105 消费"))
        XCTAssertEqual(byTailAndKind.count, 3)
        let noMatch = try await backend.records(filter: RecordFilter(text: "0105 工资"))
        XCTAssertTrue(noMatch.isEmpty)
        let inflow = try await backend.records(filter: RecordFilter(direction: .inflow))
        XCTAssertTrue(inflow.isEmpty)
        let period = try await backend.records(filter: RecordFilter(from: now.addingTimeInterval(90), to: now.addingTimeInterval(150)))
        XCTAssertEqual(period.map(\.record.amountMinor), [100_00])
    }

    // MARK: 卡片信息

    func testCardInfoCanChangeTypePrimaryCurrencyAndOpeningBalances() async throws {
        let backend = try makeBackend()
        let account = try await addAccount(backend, last4: "0427", opening: 500_00)
        try await addAccount(backend, last4: "0427", type: .credit)
        do {
            try await backend.updateAccount(id: account.id, AccountEdit(
                name: account.name, cardType: .credit, currency: .cny, extraCurrencies: [], cardNumber: nil, accountNumber: nil
            ))
            XCTFail("和已有的信用卡重复")
        } catch BackendError.invalidAccount(.duplicateAccount) {}

        // 主币种改成港币，人民币变成其他币种：人民币的初始余额保留；填港币的初始余额
        try await backend.updateAccount(id: account.id, AccountEdit(
            name: "", cardType: .prepaid, currency: .hkd, extraCurrencies: [.cny, .hkd], cardNumber: nil, accountNumber: "100-200xxx-300",
            openingBalanceChanges: [OpeningBalanceChange(currency: .hkd, amountMinor: 200_00), OpeningBalanceChange(currency: .usd, amountMinor: 1)]
        ))
        var accounts = try await backend.accounts()
        var stored = try XCTUnwrap(accounts.first { $0.id == account.id })
        XCTAssertEqual(stored.cardType, .prepaid)
        XCTAssertEqual(stored.name, "招商银行预付卡", "留空恢复默认名称")
        XCTAssertEqual(stored.currencies, [.hkd, .cny])
        XCTAssertEqual(stored.openingBalance(.cny)?.amountMinor, 500_00)
        XCTAssertEqual(stored.openingBalance(.hkd)?.amountMinor, 200_00)
        XCTAssertNil(stored.openingBalance(.usd), "卡里没有的币种不保存初始余额")
        XCTAssertEqual(stored.accountNumber, "100-200XXX-300")

        // 改回单币种：人民币的初始余额删除；清除港币的初始余额
        try await backend.updateAccount(id: account.id, AccountEdit(
            name: "日常卡", cardType: .debit, currency: .hkd, extraCurrencies: [], cardNumber: "", accountNumber: nil,
            openingBalanceChanges: [OpeningBalanceChange(currency: .hkd, amountMinor: nil)]
        ))
        accounts = try await backend.accounts()
        stored = try XCTUnwrap(accounts.first { $0.id == account.id })
        XCTAssertEqual(stored.currencies, [.hkd])
        XCTAssertTrue(stored.openingBalances.isEmpty)
        XCTAssertEqual(stored.name, "日常卡")
        XCTAssertNil(stored.accountNumber)

        do {
            try await backend.updateAccount(id: account.id, AccountEdit(
                name: "", cardType: .debit, currency: .hkd, extraCurrencies: [], cardNumber: "6225880112340000", accountNumber: nil
            ))
            XCTFail("卡号末四位和尾号不一致")
        } catch BackendError.invalidAccount(.invalidCardNumber) {}
    }

    func testDeletingArchivedAccountKeepsItsRecords() async throws {
        let backend = try makeBackend()
        let card = try await addAccount(backend, last4: "0427", opening: 500_00)
        let other = try await addAccount(backend, last4: "1234")
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms, receivedAt: now))
        _ = try await backend.addRecord(ManualEntry(type: .transfer, accountID: card.id, toAccountID: other.id, amountMinor: 100_00, currency: .cny, time: now))
        let before = try await backend.recordCount()
        XCTAssertEqual(before, 3)

        do {
            try await backend.deleteAccount(id: card.id)
            XCTFail("使用中的账户要先停用")
        } catch BackendError.accountNotArchived {}

        try await backend.setArchived(accountID: card.id, archived: true)
        try await backend.deleteAccount(id: card.id)
        let accounts = try await backend.accounts(includeArchived: true)
        XCTAssertEqual(accounts.map(\.id), [other.id], "删除的账户不在账户列表里")
        let everything = try await backend.accounts(includeArchived: true, includeDeleted: true)
        let deleted = try XCTUnwrap(everything.first { $0.id == card.id })
        XCTAssertTrue(deleted.deleted)
        XCTAssertEqual(deleted.displayTitle, "招商银行 ·0427（已删除）")
        let balances = try await backend.balanceSummaries()
        XCTAssertNil(balances[card.id], "不算进余额和净资产")

        let after = try await backend.recordCount()
        XCTAssertEqual(after, 3, "流水都留着")
        let own = try await firstRow(backend, accountID: card.id)
        XCTAssertEqual(own.account.text, "招商银行 ·0427（已删除）")
        let peer = try await firstRow(backend, accountID: other.id)
        XCTAssertNotNil(peer.record.transferGroupID, "转帐两边都在，还是内部转帐")
        XCTAssertEqual(peer.peer?.text, "招商银行 ·0427（已删除）")
        XCTAssertEqual(peer.account.text, "招商银行 ·1234")

        // 同一条通知再来不会重新记上；同尾号的卡可以重新添加，之后的通知记到新卡上
        _ = try await backend.ingest(IngestRequest(text: purchase, source: .sms, receivedAt: now))
        let again = try await backend.recordCount()
        XCTAssertEqual(again, 3)
        let readded = try await addAccount(backend, last4: "0427")
        _ = try await backend.ingest(IngestRequest(
            text: "【招商银行】您尾号0427的储蓄卡于10月24日16:00在全家便利店消费人民币12.00元。", source: .sms, receivedAt: now.addingTimeInterval(60)
        ))
        let newCount = try await backend.recordCount(accountID: readded.id)
        XCTAssertEqual(newCount, 1)

        do {
            try await backend.deleteAccount(id: card.id)
            XCTFail("已经删除过")
        } catch BackendError.notFound {}
    }

    // MARK: 银行和币种列表

    func testBankCatalogFindsBanksByAnyName() {
        XCTAssertEqual(Set(BankCatalog.all.map(\.id)).count, BankCatalog.all.count, "标识不重复")
        for profile in BankDirectory.all {
            XCTAssertNotNil(BankCatalog.entry(id: profile.id), "能识别通知的银行都在列表里：\(profile.id)")
        }
        XCTAssertEqual(BankCatalog.search("招行").first?.id, "cmb")
        XCTAssertEqual(BankCatalog.search("hsbc").first?.id, "hsbc")
        XCTAssertEqual(BankCatalog.search("Hang Seng").first?.id, "hangseng")
        XCTAssertEqual(BankCatalog.search("恒生").first?.id, "hangseng")
        XCTAssertEqual(BankCatalog.search("滙豐").first?.id, "hsbc")
        XCTAssertEqual(BankCatalog.search("ＩＣＢＣ").first?.id, "icbc", "全角也能搜")
        XCTAssertEqual(BankCatalog.search("みずほ").first?.id, "mizuho")
        XCTAssertEqual(BankCatalog.search("국민은행").first?.id, "kb")
        XCTAssertEqual(BankCatalog.search("societe generale").first?.id, "socgen", "不分重音")
        XCTAssertTrue(BankCatalog.search("   ").isEmpty)
        XCTAssertLessThanOrEqual(BankCatalog.search("银行").count, 8)
        XCTAssertEqual(BankCatalog.exactMatch("工商银行")?.id, "icbc")
        XCTAssertNil(BankCatalog.exactMatch("工商"))
    }

    func testSupportedCurrenciesCoverCommonOnesWithoutDuplicates() {
        XCTAssertEqual(Set(CurrencyCode.supported).count, CurrencyCode.supported.count)
        XCTAssertGreaterThanOrEqual(CurrencyCode.supported.count, 160)
        for code in CurrencyCode.common {
            XCTAssertTrue(CurrencyCode.supported.contains(code), code.rawValue)
        }
        XCTAssertEqual(CurrencyCode.hkd.chineseName, "港币")
        XCTAssertEqual(CurrencyCode("FOK").chineseName, "法罗群岛克朗")
        XCTAssertEqual(CurrencyCode("XAF").minorUnitExponent, 0)
    }
}
