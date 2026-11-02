import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 用户手机上收到的通知（`NoticeSamples`），每条走完整的入账流程，核对最后记成了什么。
final class RealSampleTests: XCTestCase {
    let now = ParserSampleTests.reference

    func makeBackend() throws -> LedgerBackend {
        let now = self.now
        return LedgerBackend(database: try Database.inMemory(), calendar: ParserSampleTests.calendar, clock: { now })
    }

    func addCards(_ backend: LedgerBackend) async throws {
        let cards: [(String?, String, String, CardType, CurrencyCode)] = [
            ("boc", "中国银行", "0001", .debit, .cny), ("boc", "中国银行", "0006", .debit, .cny), ("cmb", "招商银行", "0002", .debit, .cny),
            (nil, "众安银行", "0003", .debit, .hkd), (nil, "恒生银行", "0004", .debit, .hkd), ("ccb", "建设银行", "0005", .credit, .cny),
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
            if let settlement = r.settlement {
                line += " 实扣" + MoneyFormat.plain(settlement.minorUnits, exponent: settlement.currency.minorUnitExponent, grouping: false)
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
        for (index, sample) in NoticeSamples.all.enumerated() {
            let actual = try await describe(sample.text, at: now.addingTimeInterval(Double(index) * 60), in: backend)
            if actual != sample.expected { wrong.append("#\(index + 1) 应为「\(sample.expected)」，实际「\(actual)」") }
        }
        print("真实样本：\(NoticeSamples.all.count - wrong.count)/\(NoticeSamples.all.count) 正确")
        for line in wrong { print(line) }
        XCTAssertEqual(wrong, [])
    }

    /// 三笔完成扣款各自了结对应的冻结，中行那笔没有完成扣款的通知，还冻结着
    func testCapturesCloseTheirHolds() async throws {
        let backend = try makeBackend()
        try await addCards(backend)
        for (index, sample) in NoticeSamples.all.enumerated() {
            _ = try await backend.ingest(IngestRequest(text: sample.text, source: .auto, receivedAt: now.addingTimeInterval(Double(index) * 60)))
        }
        let statuses = try await backend.records(limit: 200).map(\.record)
        XCTAssertEqual(statuses.filter { $0.status == .holdReleased }.count, 3)
        XCTAssertEqual(statuses.filter { $0.status == .hold }.map(\.currency), [.usd])
    }

    /// 还没添加这些卡时：交易都等用户选卡，不会记到别处；不是交易的照样忽略
    func testWithoutCardsNothingIsRecorded() async throws {
        let backend = try makeBackend()
        var wrong: [String] = []
        for (index, sample) in NoticeSamples.all.enumerated() {
            let actual = try await describe(sample.text, at: now.addingTimeInterval(Double(index) * 60), in: backend)
            let good = sample.expected == "忽略" ? actual == "忽略" : actual.hasPrefix("待处理")
            if !good { wrong.append("#\(index + 1) 实际「\(actual)」") }
        }
        XCTAssertEqual(wrong, [])
    }
}
