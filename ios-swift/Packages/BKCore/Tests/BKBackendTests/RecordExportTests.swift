import Foundation
import XCTest
@testable import BKBackend
import BKDatabase
import BKModel

/// 导出流水的 CSV。商户、尾号、金额都是假的。
final class RecordExportTests: XCTestCase {
    func testExportWritesEveryRecordAsCSV() async throws {
        let backend = try LedgerBackend.inMemory(calendar: ParserSampleTests.calendar, clock: { ParserSampleTests.reference })
        _ = try await backend.addAccount(AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "ocean"))
        let text = "您尾号8810的信用卡10月20日12:01消费人民币11.00元，商户：财付通-测试外卖。【中国银行】"
        let result = try await backend.ingest(IngestRequest(text: text, source: .sms, receivedAt: ParserSampleTests.reference))
        let id = try XCTUnwrap(result.items.first?.recordID)
        let categories = try await backend.categories()
        let lunch = try XCTUnwrap(categories.first { $0.name == "午餐" })
        try await backend.setCategory(recordID: id, categoryID: lunch.id, note: #"午饭, 和"同事""#)
        let row = try await backend.recordDetail(id: id).row

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await backend.exportRecords(to: url)
        XCTAssertEqual(count, 1)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "带 BOM，Excel 才认得出中文")
        let text2 = String(decoding: data.dropFirst(3), as: UTF8.self)
        let lines = text2.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3, "表头、一笔、最后的空行")
        XCTAssertEqual(lines[0], RecordCSV.header.joined(separator: ","))
        let counterparty = row.record.counterparty ?? ""
        XCTAssertTrue(
            lines[1].hasSuffix(#",支出,饮食,午餐,-11.00,CNY,中国银行 ·8810,,\#(counterparty),"午饭, 和""同事""",消费,已入账,短信,,,"#),
            lines[1]
        )
        XCTAssertNotNil(lines[1].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},"#, options: .regularExpression), "时间写到秒")
    }

    func testEscapingOnlyWhenNeeded() {
        XCTAssertEqual(RecordCSV.escape("午餐"), "午餐")
        XCTAssertEqual(RecordCSV.escape("a,b"), #""a,b""#)
        XCTAssertEqual(RecordCSV.escape(#"说"好""#), #""说""好""""#)
        XCTAssertEqual(RecordCSV.escape("两\n行"), "\"两\n行\"")
    }
}
