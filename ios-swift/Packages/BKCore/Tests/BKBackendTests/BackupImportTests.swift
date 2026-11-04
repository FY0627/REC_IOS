import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 导入导出的 zip（ADR 0019）：覆盖、增量、撤销、读不了的文件。商户、尾号、金额都是假的。
final class BackupImportTests: XCTestCase {
    func makeBackend() async throws -> (LedgerBackend, Account) {
        let backend = try LedgerBackend.inMemory(calendar: ParserSampleTests.calendar, clock: { ParserSampleTests.reference })
        let account = try await backend.addAccount(AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean"))
        return (backend, account)
    }

    @discardableResult
    func spend(_ backend: LedgerBackend, minute: Int, at merchant: String) async throws -> String {
        let text = "您尾号8810的信用卡10月20日12:\(String(format: "%02d", minute))消费人民币\(10 + minute).00元，商户：\(merchant)。【中国银行】"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference.addingTimeInterval(Double(minute) * 60)))
        return try XCTUnwrap(result.items.first?.recordID)
    }

    func archive(_ backend: LedgerBackend) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await backend.exportData(to: url)
        return try Data(contentsOf: url)
    }

    func counterparties(_ backend: LedgerBackend) async throws -> [String] {
        try await backend.records(limit: 100).compactMap(\.record.counterparty).sorted()
    }

    func testReplaceSwapsEverythingForTheBackup() async throws {
        let (source, _) = try await makeBackend()
        try await spend(source, minute: 1, at: "测试早餐")
        try await spend(source, minute: 2, at: "测试午餐")
        let zip = try await archive(source)

        let target = try LedgerBackend.inMemory(calendar: ParserSampleTests.calendar, clock: { ParserSampleTests.reference })
        _ = try await target.addAccount(AccountDraft(name: "", bankID: "icbc", bankName: "工商银行", last4: "9999", cardType: .debit, currency: .cny, paletteID: "crimson"))
        let info = try await target.backupInfo(archive: zip)
        XCTAssertEqual(info.records, 2)
        XCTAssertEqual(info.accounts, 1)

        let summary = try await target.importBackup(archive: zip, mode: .replace, keepFaceImage: { _ in false })
        XCTAssertEqual(summary.records, 2)
        let accounts = try await target.accounts()
        XCTAssertEqual(accounts.map(\.last4), ["8810"], "原来的工行卡没了，全部换成备份里的")
        let names = try await counterparties(target)
        XCTAssertEqual(names, ["测试午餐", "测试早餐"].sorted())
    }

    func testMergeAddsOnlyWhatIsMissing() async throws {
        let (source, _) = try await makeBackend()
        try await spend(source, minute: 1, at: "测试早餐")
        try await spend(source, minute: 2, at: "测试午餐")
        let pet = try await source.addCategory(CategoryDraft(type: .expense, parentID: nil, name: "宠物", symbol: "pawprint"))
        let food = try await spend(source, minute: 3, at: "测试猫粮")
        try await source.setCategory(recordID: food, categoryID: pet.id)
        let zip = try await archive(source)

        // 另一台手机（或重装后）：同一张卡重新添加过（编号不同），同一条通知也记过，还有自己的一笔
        let (target, card) = try await makeBackend()
        try await spend(target, minute: 1, at: "测试早餐")
        try await spend(target, minute: 4, at: "测试晚餐")
        let localPet = try await target.addCategory(CategoryDraft(type: .expense, parentID: nil, name: "宠物", symbol: "pawprint"))

        let summary = try await target.importBackup(archive: zip, mode: .merge, keepFaceImage: { _ in true })
        XCTAssertEqual(summary.records, 2, "午餐和猫粮是新的")
        XCTAssertEqual(summary.existingRecords, 1, "早餐是同一条通知，不再加")
        XCTAssertEqual(summary.accounts, 0)
        XCTAssertEqual(summary.existingAccounts, 1)
        XCTAssertEqual(summary.categories, 0, "同名的「宠物」就是这里的那个")

        let accounts = try await target.accounts()
        XCTAssertEqual(accounts.map(\.id), [card.id], "同一家银行、同一个尾号、同一种卡就是同一张")
        let rows = try await target.records(limit: 100)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.record.accountID == card.id })
        XCTAssertEqual(rows.first { $0.record.counterparty == "测试猫粮" }?.record.categoryID, localPet.id)

        let again = try await target.importBackup(archive: zip, mode: .merge, keepFaceImage: { _ in true })
        XCTAssertEqual(again.records, 0, "再导入一次什么也不加")
        let count = try await target.records(limit: 100).count
        XCTAssertEqual(count, 4)
    }

    func testCopyTakenBeforeImportUndoesIt() async throws {
        let (source, _) = try await makeBackend()
        try await spend(source, minute: 1, at: "测试早餐")
        let zip = try await archive(source)

        let (target, _) = try await makeBackend()
        try await spend(target, minute: 5, at: "测试晚餐")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await target.saveDatabaseCopy(to: copy)
        _ = try await target.importBackup(archive: zip, mode: .replace, keepFaceImage: { _ in true })
        let replaced = try await counterparties(target)
        XCTAssertEqual(replaced, ["测试早餐"])

        _ = try await target.importDatabase(at: copy, mode: .replace, keepFaceImage: { _ in true })
        let restored = try await counterparties(target)
        XCTAssertEqual(restored, ["测试晚餐"])
    }

    func testUnreadableAndNewerBackupsAreRefused() async throws {
        let (target, _) = try await makeBackend()
        do {
            _ = try await target.importBackup(archive: Data("不是 zip".utf8), mode: .merge, keepFaceImage: { _ in true })
            XCTFail("不是 zip")
        } catch {
            XCTAssertEqual(error as? BackendError, .backupUnreadable)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let newer = try SQLiteConnection(path: url.path)
            try Migrations.migrate(newer)
            try newer.setUserVersion(Migrations.latestVersion + 1)
        }
        do {
            _ = try await target.importDatabase(at: url, mode: .replace, keepFaceImage: { _ in true })
            XCTFail("比 App 新的备份")
        } catch {
            XCTAssertEqual(error as? BackendError, .backupTooNew)
        }
        let count = try await target.records(limit: 10).count
        XCTAssertEqual(count, 0, "导入失败什么也不改")
    }
}
