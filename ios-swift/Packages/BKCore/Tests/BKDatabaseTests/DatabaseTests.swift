import Foundation
import XCTest
@testable import BKDatabase
import BKModel

final class DatabaseTests: XCTestCase {
    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-db-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.sqlite").path
    }

    private func account(_ last4: String, id: String = UUID().uuidString) -> Account {
        Account(id: id, name: "测试卡", bankID: "cmb", bankName: "招商银行", last4: last4, cardType: .debit, currency: .cny, paletteID: "ocean", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testMigrationCreatesSchemaAndIsIdempotent() throws {
        let path = tempPath()
        do {
            let db = try Database(path: path)
            XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        }
        // 重新打开不会重复执行迁移
        let reopened = try Database(path: path)
        XCTAssertEqual(try reopened.readSync { $0.userVersion }, Migrations.latestVersion)
        let tables = try reopened.readSync { db in
            try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { $0.string(0) }
        }
        for table in ["accounts", "balance_observations", "ingests", "pending_items", "record_evidence", "records", "settings"] {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
    }

    func testMigrationFromVersion1KeepsAccountsAndAddsOpeningBalance() throws {
        let path = tempPath()
        do {
            // 模拟已经装了旧版本的账本：只有第 1 版表结构和一张卡
            let old = try SQLiteConnection(path: path)
            try old.execute(Migrations.steps[0].sql)
            try old.setUserVersion(1)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "CNY", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000)]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let stored = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(stored.last4, "0427")
        XCTAssertNil(stored.openingBalanceMinor)
        let at = Date(timeIntervalSince1970: 1_790_000_100)
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .cny, amountMinor: -12_345, at: at) })
        let updated = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(updated.openingBalanceMinor, -12_345)
        XCTAssertEqual(updated.openingBalanceAt, at)
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .cny, amountMinor: nil, at: at) })
        let cleared = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertNil(cleared.openingBalanceMinor)
        XCTAssertNil(cleared.openingBalanceAt, "清除时时间一起清除")
    }

    func testMigrationFromVersion2AddsCardNumberAndFace() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            try old.execute(Migrations.steps[0].sql)
            try old.execute(Migrations.steps[1].sql)
            try old.setUserVersion(2)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, opening_balance_minor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "CNY", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000), 5_000]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let stored = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(stored.openingBalanceMinor, 5_000)
        XCTAssertNil(stored.cardNumber)
        XCTAssertEqual(stored.face, .standard, "旧卡使用默认卡面")

        let face = CardFace(imageID: "img-1", textColor: 0xFFEEDD, textScale: 1.2)
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateFace($0, id: "a1", paletteID: "jade", face: face) })
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateInfo($0, id: "a1", name: "工资卡", cardNumber: "6225880112340427") })
        let updated = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(updated.paletteID, "jade")
        XCTAssertEqual(updated.face, face)
        XCTAssertEqual(updated.name, "工资卡")
        XCTAssertEqual(updated.cardNumber, "6225880112340427")
    }

    func testMigrationFromVersion3MovesOpeningBalanceToPerCurrencyTable() throws {
        let path = tempPath()
        let at = Date(timeIntervalSince1970: 1_790_000_500)
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 3 { try old.execute(step.sql) }
            try old.setUserVersion(3)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, opening_balance_minor, opening_balance_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "HKD", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000), -7_000, at]
            )
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a2", "测试卡", "cmb", "招商银行", "0428", "debit", "CNY", "ocean", 1, Date(timeIntervalSince1970: 1_790_000_000)]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let accounts = try db.readSync { try AccountDAO.all($0) }
        let first = try XCTUnwrap(accounts.first { $0.id == "a1" })
        XCTAssertEqual(first.extraCurrencies, [])
        XCTAssertEqual(first.openingBalances, [OpeningBalance(currency: .hkd, amountMinor: -7_000, at: at)])
        XCTAssertEqual(accounts.first { $0.id == "a2" }?.openingBalances, [])

        try db.writeSync { try AccountDAO.updateExtraCurrencies($0, id: "a1", primary: .hkd, extras: [.usd, .cny]) }
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .usd, amountMinor: 100, at: at) })
        XCTAssertFalse(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "missing", currency: .usd, amountMinor: 100, at: at) })
        let reloaded = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(reloaded.currencies, [.hkd, .usd, .cny])
        XCTAssertEqual(reloaded.openingBalance(.usd)?.amountMinor, 100)
        XCTAssertEqual(reloaded.openingBalanceMinor, -7_000, "主币种的初始余额")
    }

    func testMigrationFromVersion4AddsAccountNumberAndTransferParty() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 4 { try old.execute(step.sql) }
            try old.setUserVersion(4)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "x", "恒生银行", "0104", "debit", "HKD", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000)]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        XCTAssertNil(try db.readSync { try AccountDAO.find($0, id: "a1") }?.accountNumber)
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateAccountNumber($0, id: "a1", accountNumber: "100-200XXX-300") })
        XCTAssertEqual(try db.readSync { try AccountDAO.find($0, id: "a1") }?.accountNumber, "100-200XXX-300")
        XCTAssertEqual(try db.readSync { try RecordDAO.unconfirmedTransferCount($0) }, 0)
    }

    func testMigrationFromVersion5AddsMessageTemplates() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 5 { try old.execute(step.sql) }
            try old.setUserVersion(5)
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let template = MessageTemplate(
            id: "t1", name: "测试", pieces: [.text("您尾号"), .cardTail, .text("消费"), .amount, .text("元，余额"), .anyNumber],
            kind: .purchase, direction: .outflow, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        try db.writeSync { try TemplateDAO.save($0, template) }
        XCTAssertEqual(try db.readSync { try TemplateDAO.all($0) }, [template])
        XCTAssertTrue(try db.writeSync { try TemplateDAO.delete($0, id: "t1") })
        XCTAssertEqual(try db.readSync { try TemplateDAO.all($0) }, [])
    }

    func testMigrationFromVersion6AddsSettlementAndDailyRates() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 6 { try old.execute(step.sql) }
            try old.setUserVersion(6)
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let fetched = Date(timeIntervalSince1970: 1_790_000_000)
        let rates = ExchangeRates(base: .usd, rates: ["CNY": 7.2, "HKD": 7.8, "BAD": 0], updatedAt: fetched, fetchedAt: fetched)
        XCTAssertTrue(try db.writeSync { try RateDAO.save($0, day: "2026-10-24", rates: rates) })
        XCTAssertFalse(try db.writeSync { try RateDAO.save($0, day: "2026-10-24", rates: rates) }, "同一份下载不重复写")
        XCTAssertEqual(try db.readSync { try RateDAO.days($0) }, ["2026-10-24"])
        XCTAssertEqual(try db.readSync { try RateDAO.rates($0, day: "2026-10-24") }, ["USD": 1, "CNY": 7.2, "HKD": 7.8], "基准币种补上 1，无效汇率去掉")
        var newer = rates
        newer.fetchedAt = fetched.addingTimeInterval(3600)
        newer.rates["CNY"] = 7.3
        XCTAssertTrue(try db.writeSync { try RateDAO.save($0, day: "2026-10-24", rates: newer) }, "同一天更晚的下载覆盖")
        XCTAssertEqual(try db.readSync { try RateDAO.rates($0, day: "2026-10-24") }["CNY"], 7.3)
    }

    func testMigrationFromVersion7AddsCategoriesAndBackfillsAutomaticOnes() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 7 { try old.execute(step.sql) }
            try old.setUserVersion(7)
            try old.execute("""
            INSERT INTO accounts (id, name, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES ('a', '卡', '银行', '0427', 'debit', 'CNY', 'ocean', 0, 0);
            INSERT INTO ingests (id, fingerprint, source, processed_at, classification, outcome, parser_version) VALUES ('i', 'f', 'sms', 0, 'transaction', 'recorded', 1);
            INSERT INTO records (id, account_id, amount_minor, currency, direction, kind, status, processed_at, effective_at, source, ingest_id, part_index, dedupe_key, created_at)
                VALUES ('fee', 'a', 200, 'CNY', 'outflow', 'fee', 'posted', 0, 0, 'sms', 'i', 1, 'k1', 0),
                       ('pay', 'a', 3800, 'CNY', 'outflow', 'purchase', 'posted', 0, 0, 'sms', 'i', 0, 'k2', 0);
            """)
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let categories = try db.readSync { try CategoryDAO.all($0) }
        let tree = CategoryTree(categories)
        XCTAssertEqual(tree.nodes(.expense).first?.category.name, "饮食")
        XCTAssertEqual(tree.nodes(.expense).first?.children.map(\.name), ["早餐", "午餐", "晚餐", "饮料零食"])
        XCTAssertEqual(tree.nodes(.income).map(\.category.name), ["工资", "奖金", "利息理财", "红包和转来的钱", "其他"])
        XCTAssertTrue(tree.nodes(.income).allSatisfy(\.children.isEmpty), "收入默认只有一层")
        XCTAssertEqual(tree.nodes(.transfer).count, 3)
        XCTAssertTrue(tree.nodes(.transfer).allSatisfy(\.category.locked))
        let records = try db.readSync { try RecordDAO.page($0, filter: RecordFilter(), before: nil, limit: 10) }
        XCTAssertEqual(records.first { $0.id == "fee" }?.record.categoryID, "sys.fee", "手续费补上系统分类")
        XCTAssertNil(records.first { $0.id == "pay" }?.record.categoryID, "消费是待分类")
        XCTAssertEqual(try db.readSync { try RecordDAO.uncategorizedCount($0) }, 1)
    }

    func testMigrationFromVersion8KeepsAccountsAndMarksDeletedOnly() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 8 { try old.execute(step.sql) }
            try old.setUserVersion(8)
            try old.execute("""
            INSERT INTO accounts (id, name, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, archived) VALUES ('a', '卡', '银行', '0427', 'debit', 'CNY', 'ocean', 0, 0, 1);
            INSERT INTO ingests (id, fingerprint, source, processed_at, classification, outcome, parser_version) VALUES ('i', 'f', 'sms', 0, 'transaction', 'recorded', 1);
            INSERT INTO records (id, account_id, amount_minor, currency, direction, kind, status, processed_at, effective_at, source, ingest_id, part_index, dedupe_key, created_at)
                VALUES ('pay', 'a', 3800, 'CNY', 'outflow', 'purchase', 'posted', 0, 0, 'sms', 'i', 0, 'k', 0);
            """)
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        XCTAssertEqual(try db.readSync { try AccountDAO.all($0, includeArchived: true) }.map(\.deleted), [false])

        XCTAssertTrue(try db.writeSync { try AccountDAO.markDeleted($0, id: "a", at: Date(timeIntervalSince1970: 100)) })
        XCTAssertTrue(try db.readSync { try AccountDAO.all($0, includeArchived: true) }.isEmpty)
        XCTAssertEqual(try db.readSync { try AccountDAO.all($0, includeArchived: true, includeDeleted: true) }.map(\.deletedAt), [Date(timeIntervalSince1970: 100)])
        let rows = try db.readSync { try RecordDAO.page($0, filter: RecordFilter(), before: nil, limit: 10) }
        XCTAssertEqual(rows.map(\.id), ["pay"], "流水留着")
        XCTAssertEqual(rows.first?.account.text, "银行 ·0427（已删除）")
    }

    func testMigrationFromVersion9KeepsFaceAndPutsAmountTopRight() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 9 { try old.execute(step.sql) }
            try old.setUserVersion(9)
            try old.execute("""
            INSERT INTO accounts (id, name, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, face_image_id, face_text_color, face_text_scale)
                VALUES ('a', '卡', '银行', '0427', 'debit', 'CNY', 'ocean', 0, 0, 'img', 16777215, 1.1);
            """)
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let stored = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a") })
        XCTAssertEqual(stored.face, CardFace(imageID: "img", textColor: 0xFFFFFF, textScale: 1.1))
        XCTAssertNil(stored.face.outlineColor)
        XCTAssertEqual(stored.face.amountX, 1)
        XCTAssertEqual(stored.face.amountY, 0)

        let face = CardFace(imageID: "img", outlineColor: 0x102030, amountX: 0.4, amountY: 0.6)
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateFace($0, id: "a", paletteID: "ocean", face: face) })
        XCTAssertEqual(try db.readSync { try AccountDAO.find($0, id: "a") }?.face, face)
    }

    func testAmountKeywordsMatchEachMinorUnit() {
        XCTAssertEqual(RecordDAO.amountMinors("38").map(\.minor), [38, 3800, 38000])
        XCTAssertEqual(RecordDAO.amountMinors("38.5").map(\.exponent), [2, 3])
        XCTAssertEqual(RecordDAO.amountMinors("38.5").map(\.minor), [3850, 38500])
        XCTAssertEqual(RecordDAO.amountMinors("1,234.56").map(\.minor), [123_456, 1_234_560])
        XCTAssertEqual(RecordDAO.amountMinors("12,50").map(\.minor), [1250, 12500], "欧洲写法的小数逗号")
        XCTAssertEqual(RecordDAO.amountMinors("38.00").map(\.minor), [38, 3800, 38000])
        XCTAssertTrue(RecordDAO.amountMinors("星巴克").isEmpty)
        XCTAssertTrue(RecordDAO.amountMinors("38.").isEmpty)
        XCTAssertEqual(RecordDAO.escapeLike("50%_a\\b"), "50\\%\\_a\\\\b")
    }

    func testLeadingZeroLast4SurvivesReopen() throws {
        let path = tempPath()
        do {
            let db = try Database(path: path)
            try db.writeSync { try AccountDAO.insert($0, account("0042", id: "a1")) }
        }
        let reopened = try Database(path: path)
        let stored = try reopened.readSync { try AccountDAO.find($0, id: "a1") }
        XCTAssertEqual(stored?.last4, "0042")
    }

    func testLast4ConstraintRejectsInvalidValues() throws {
        let db = try Database.inMemory()
        for invalid in ["123", "12345", "12a4"] {
            XCTAssertThrowsError(try db.writeSync { try AccountDAO.insert($0, account(invalid)) }, "accepted \(invalid)")
        }
    }

    func testFailedTransactionRollsBackCompletely() throws {
        let db = try Database.inMemory()
        struct Boom: Error {}
        XCTAssertThrowsError(try db.writeSync { conn in
            try AccountDAO.insert(conn, account("1111", id: "x"))
            throw Boom()
        })
        XCTAssertNil(try db.readSync { try AccountDAO.find($0, id: "x") })
    }

    func testWallClockCodecRoundTrip() {
        let clock = WallClock(year: 2026, month: 10, day: 4, hour: 9, minute: 5, second: nil)
        XCTAssertEqual(WallClockCodec.encode(clock), "2026-10-04T09:05")
        XCTAssertEqual(WallClockCodec.decode("2026-10-04T09:05", yearInferred: false), clock)
        let timeOnly = WallClock(year: nil, month: nil, day: nil, hour: 14, minute: 30)
        XCTAssertEqual(WallClockCodec.decode(WallClockCodec.encode(timeOnly), yearInferred: false)?.hour, 14)
    }
}
