import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 导出全部数据：一个 zip，里面每种数据一个 CSV 和一份数据库副本。商户、尾号、卡号、金额都是假的。
final class DataExportTests: XCTestCase {
    func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }

    func testZipRoundTripKeepsChineseNames() throws {
        let entries = [
            ZipStore.Entry(name: "REC 数据/流水.csv", data: Data("时间,金额\r\n".utf8)),
            ZipStore.Entry(name: "REC 数据/空.txt", data: Data()),
        ]
        let zip = ZipStore.archive(entries, modified: ParserSampleTests.reference, calendar: ParserSampleTests.calendar)
        XCTAssertEqual(try ZipStore.entries(zip), entries)
        XCTAssertThrowsError(try ZipStore.entries(Data("不是 zip".utf8)))
        var damaged = zip
        // 第一个文件内容里的一个字节（本地文件头 30 字节，后面是文件名）
        damaged[30 + Data(entries[0].name.utf8).count + 2] ^= 0xFF
        XCTAssertThrowsError(try ZipStore.entries(damaged), "内容对不上校验码")
    }

    func testExportWritesEveryKindOfData() async throws {
        let backend = try LedgerBackend.inMemory(calendar: ParserSampleTests.calendar, clock: { ParserSampleTests.reference })
        let account = try await backend.addAccount(AccountDraft(
            name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean", openingBalanceMinor: 100_000
        ))
        try await backend.updateCardInfo(accountID: account.id, name: "", cardNumber: "6200000000008810")
        let text = "您尾号8810的信用卡10月20日12:01消费人民币11.00元，商户：财付通-测试外卖。【中国银行】"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference))
        let id = try XCTUnwrap(result.items.first?.recordID)
        let categories = try await backend.categories()
        let lunch = try XCTUnwrap(categories.first { $0.name == "午餐" })
        try await backend.setCategory(recordID: id, categoryID: lunch.id, note: #"午饭, 和"同事""#)
        let row = try await backend.recordDetail(id: id).row

        let url = temporaryURL("REC 数据 2026-10-20.zip")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let summary = try await backend.exportData(to: url)
        XCTAssertEqual(summary.records, 1)
        XCTAssertEqual(summary.accounts, 1)
        XCTAssertEqual(summary.files, ["流水.csv", "账户.csv", "余额.csv", "分类.csv", "学到的分类.csv", "识别模板.csv", "汇率.csv", "待处理.csv", "原始通知.csv", "通知里的余额.csv"])

        let entries = try ZipStore.entries(try Data(contentsOf: url))
        XCTAssertEqual(entries.map(\.name), (["说明.txt"] + summary.files + [DataExport.backupName]).map { "REC 数据 2026-10-20/\($0)" })
        func read(_ name: String) throws -> [String] {
            let data = try XCTUnwrap(entries.first { $0.name.hasSuffix("/" + name) }?.data)
            XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "\(name) 带 BOM，Excel 才认得出中文")
            return String(decoding: data.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
        }

        let records = try read("流水.csv")
        XCTAssertEqual(records.count, 3, "表头、一笔、最后的空行")
        XCTAssertEqual(records[0], DataExport.recordHeader.joined(separator: ","))
        let counterparty = row.record.counterparty ?? ""
        XCTAssertTrue(
            records[1].hasPrefix(#"\#(id),"#) && records[1].contains(
                #",支出,饮食,午餐,-11.00,CNY,中国银行 ·8810,,\#(counterparty),"午饭, 和""同事""",消费,已入账,短信,,,"#
            ),
            records[1]
        )
        XCTAssertTrue(records[1].hasSuffix(",\(row.record.ingestID)"), "原始通知的编号对得上原始通知.csv")
        XCTAssertNotNil(records[1].range(of: #"^[^,]+,\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},"#, options: .regularExpression), "时间写到秒")

        let accounts = try read("账户.csv")
        XCTAssertTrue(accounts[1].hasPrefix("\(account.id),中国银行 ·8810,"), accounts[1])
        XCTAssertTrue(accounts[1].contains(",中国银行,8810,6200000000008810,,\(CardType.credit.displayName),CNY,,ocean,使用中,"), accounts[1])

        let balances = try read("余额.csv")
        XCTAssertTrue(balances[1].hasPrefix("\(account.id),中国银行 ·8810,CNY,1000.00,"), balances[1])

        let learned = try read("学到的分类.csv")
        XCTAssertTrue(learned[1].hasPrefix("支出,测试外卖,饮食 · 午餐,1,1,"), learned[1])

        let ingests = try read("原始通知.csv")
        XCTAssertTrue(ingests[1].hasPrefix("\(row.record.ingestID),短信,"), ingests[1])
        XCTAssertTrue(ingests[1].hasSuffix(",\(text)"), "原文在最后一列")

        let categoryLines = try read("分类.csv")
        XCTAssertTrue(categoryLines.contains { $0.hasPrefix("\(lunch.id),支出,饮食,午餐,") })
    }

    func testEscapingOnlyWhenNeeded() {
        XCTAssertEqual(DataExport.escape("午餐"), "午餐")
        XCTAssertEqual(DataExport.escape("a,b"), #""a,b""#)
        XCTAssertEqual(DataExport.escape(#"说"好""#), #""说""好""""#)
        XCTAssertEqual(DataExport.escape("两\n行"), "\"两\n行\"")
    }
}
