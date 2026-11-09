import Foundation
import BKModel

/// 数据访问函数。全部接收 `SQLiteConnection`，只能在 `Database.read/write` 的闭包里调用。
public enum AccountDAO {
    static let columns = "id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, archived, card_number, face_image_id, face_text_color, face_text_scale, extra_currencies, account_number, deleted_at, face_outline_color, face_amount_x, face_amount_y"

    static func map(_ row: SQLiteConnection.Row) -> Account {
        let currency = CurrencyCode(row.string(6))
        return Account(
            id: row.string(0), name: row.string(1), bankID: row.optionalString(2), bankName: row.string(3),
            last4: row.string(4), cardType: CardType(rawValue: row.string(5)) ?? .other,
            currency: currency, extraCurrencies: decodeCurrencies(row.string(15)),
            paletteID: row.string(7), sortOrder: Int(row.int(8)),
            createdAt: row.date(9), archived: row.bool(10), deletedAt: row.optionalDate(17),
            cardNumber: row.optionalString(11),
            accountNumber: row.optionalString(16),
            face: CardFace(
                imageID: row.optionalString(12), textColor: row.optionalInt(13).map { UInt32(truncatingIfNeeded: $0) }, textScale: row.double(14),
                outlineColor: row.optionalInt(18).map { UInt32(truncatingIfNeeded: $0) }, amountX: row.double(19), amountY: row.double(20)
            )
        )
    }

    /// 其他币种以逗号分隔保存，例如 `USD,CNY`
    static func encodeCurrencies(_ codes: [CurrencyCode]) -> String { codes.map(\.rawValue).joined(separator: ",") }
    static func decodeCurrencies(_ text: String) -> [CurrencyCode] {
        text.split(separator: ",").map { CurrencyCode(String($0)) }
    }

    /// 账户列表。删除的账户只有 `includeDeleted` 时才有（找回它的流水用）
    public static func all(_ db: SQLiteConnection, includeArchived: Bool = false, includeDeleted: Bool = false) throws -> [Account] {
        let conditions = (includeArchived ? [] : ["archived = 0"]) + (includeDeleted ? [] : ["deleted_at IS NULL"])
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        var accounts = try db.query("SELECT \(columns) FROM accounts \(filter) ORDER BY sort_order, created_at", [], map)
        let openings = Dictionary(grouping: try openingBalances(db, accountID: nil), by: \.accountID)
        for index in accounts.indices {
            accounts[index].openingBalances = openings[accounts[index].id]?.map(\.balance) ?? []
        }
        return accounts
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> Account? {
        guard var account = try db.queryOne("SELECT \(columns) FROM accounts WHERE id = ?", [id], map) else { return nil }
        account.openingBalances = try openingBalances(db, accountID: id).map(\.balance)
        return account
    }

    private static func openingBalances(_ db: SQLiteConnection, accountID: String?) throws -> [(accountID: String, balance: OpeningBalance)] {
        let sql = "SELECT account_id, currency, amount_minor, set_at FROM opening_balances" + (accountID == nil ? "" : " WHERE account_id = ?") + " ORDER BY rowid"
        let values: [SQLBindable] = accountID.map { [$0] } ?? []
        return try db.query(sql, values) { row in
            (accountID: row.string(0), balance: OpeningBalance(currency: CurrencyCode(row.string(1)), amountMinor: row.int(2), at: row.date(3)))
        }
    }

    public static func insert(_ db: SQLiteConnection, _ a: Account) throws {
        try db.run(
            "INSERT INTO accounts (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [a.id, a.name, a.bankID, a.bankName, a.last4, a.cardType.rawValue, a.currency.rawValue, a.paletteID, a.sortOrder, a.createdAt, a.archived,
             a.cardNumber, a.face.imageID, a.face.textColor.map { Int64($0) }, a.face.textScale, encodeCurrencies(a.extraCurrencies), a.accountNumber,
             a.deletedAt, a.face.outlineColor.map { Int64($0) }, a.face.amountX, a.face.amountY]
        )
        for opening in a.openingBalances {
            try setOpeningBalance(db, id: a.id, currency: opening.currency, amountMinor: opening.amountMinor, at: opening.at)
        }
    }

    public static func nextSortOrder(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM accounts"))
    }

    public static func setSortOrder(_ db: SQLiteConnection, id: String, sortOrder: Int) throws {
        try db.run("UPDATE accounts SET sort_order = ? WHERE id = ?", [sortOrder, id])
    }

    @discardableResult
    public static func updateFace(_ db: SQLiteConnection, id: String, paletteID: String, face: CardFace) throws -> Bool {
        try db.run(
            "UPDATE accounts SET palette_id = ?, face_image_id = ?, face_text_color = ?, face_text_scale = ?, face_outline_color = ?, face_amount_x = ?, face_amount_y = ? WHERE id = ?",
            [paletteID, face.imageID, face.textColor.map { Int64($0) }, face.textScale, face.outlineColor.map { Int64($0) }, face.amountX, face.amountY, id]
        ) > 0
    }

    @discardableResult
    public static func updateInfo(_ db: SQLiteConnection, id: String, name: String, cardNumber: String?) throws -> Bool {
        try db.run("UPDATE accounts SET name = ?, card_number = ? WHERE id = ?", [name, cardNumber, id]) > 0
    }

    @discardableResult
    public static func updateAccountNumber(_ db: SQLiteConnection, id: String, accountNumber: String?) throws -> Bool {
        try db.run("UPDATE accounts SET account_number = ? WHERE id = ?", [accountNumber, id]) > 0
    }

    /// 修改多币种账户的其他币种；不再持有的币种，其初始余额一起删除（已有流水保留）。
    public static func updateExtraCurrencies(_ db: SQLiteConnection, id: String, primary: CurrencyCode, extras: [CurrencyCode]) throws {
        try db.run("UPDATE accounts SET extra_currencies = ? WHERE id = ?", [encodeCurrencies(extras), id])
        try deleteOpeningBalances(db, id: id, keeping: [primary] + extras)
    }

    /// 卡片信息里能改的全部内容；不再持有的币种，其初始余额一起删除（已有流水保留）。
    public static func updateDetails(
        _ db: SQLiteConnection, id: String, name: String, cardType: CardType, currency: CurrencyCode, extras: [CurrencyCode],
        cardNumber: String?, accountNumber: String?
    ) throws {
        try db.run(
            "UPDATE accounts SET name = ?, card_type = ?, currency = ?, extra_currencies = ?, card_number = ?, account_number = ? WHERE id = ?",
            [name, cardType.rawValue, currency.rawValue, encodeCurrencies(extras), cardNumber, accountNumber, id]
        )
        try deleteOpeningBalances(db, id: id, keeping: [currency] + extras)
    }

    private static func deleteOpeningBalances(_ db: SQLiteConnection, id: String, keeping kept: [CurrencyCode]) throws {
        let placeholders = kept.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            "DELETE FROM opening_balances WHERE account_id = ? AND currency NOT IN (\(placeholders))",
            ([id] + kept.map(\.rawValue)) as [SQLBindable]
        )
    }

    public static func setArchived(_ db: SQLiteConnection, id: String, archived: Bool) throws {
        try db.run("UPDATE accounts SET archived = ? WHERE id = ?", [archived, id])
    }

    /// 删除账户：只做标记（同时停用），流水、余额都留着，账户名称后面写「已删除」；去掉自动记账指向它的引用。
    /// 通知本身（指纹）保留，同一条通知再来不会重新记上。账户不存在时返回 false
    @discardableResult
    public static func markDeleted(_ db: SQLiteConnection, id: String, at date: Date) throws -> Bool {
        guard try find(db, id: id) != nil else { return false }
        try db.run("UPDATE ingests SET bound_account_id = NULL WHERE bound_account_id = ?", [id])
        // 待处理的候选账户是逗号分隔的列表
        try db.run(
            "UPDATE pending_items SET candidate_account_ids = trim(replace(',' || candidate_account_ids || ',', ',' || ? || ',', ','), ',') WHERE instr(',' || candidate_account_ids || ',', ',' || ? || ',') > 0",
            [id, id]
        )
        try db.run("UPDATE accounts SET archived = 1, deleted_at = ? WHERE id = ?", [date, id])
        return true
    }

    /// 设置或清除某个币种的初始余额。账户不存在时返回 false。
    @discardableResult
    public static func setOpeningBalance(_ db: SQLiteConnection, id: String, currency: CurrencyCode, amountMinor: Int64?, at date: Date) throws -> Bool {
        guard try db.scalarInt("SELECT COUNT(*) FROM accounts WHERE id = ?", [id]) > 0 else { return false }
        if let amountMinor {
            try db.run(
                "INSERT INTO opening_balances (account_id, currency, amount_minor, set_at) VALUES (?, ?, ?, ?) ON CONFLICT(account_id, currency) DO UPDATE SET amount_minor = excluded.amount_minor, set_at = excluded.set_at",
                [id, currency.rawValue, amountMinor, date]
            )
        } else {
            try db.run("DELETE FROM opening_balances WHERE account_id = ? AND currency = ?", [id, currency.rawValue])
        }
        return true
    }

    public static func noteSuccess(_ db: SQLiteConnection, id: String, at date: Date, source: SourceKind) throws {
        try db.run(
            "UPDATE accounts SET last_success_at = MAX(COALESCE(last_success_at, 0), ?), last_success_source = ?, received_count = received_count + 1 WHERE id = ?",
            [date, source.rawValue, id]
        )
    }

    public static func automationStatus(_ db: SQLiteConnection) throws -> [AccountAutomationStatus] {
        try db.query("SELECT id, last_success_at, last_success_source, received_count FROM accounts", []) { row in
            AccountAutomationStatus(
                accountID: row.string(0), lastSuccessAt: row.optionalDate(1),
                lastSuccessSource: row.optionalString(2).flatMap(SourceKind.init(rawValue:)), receivedCount: Int(row.int(3))
            )
        }
    }
}

public enum RecordDAO {
    static let columns = """
    r.id, r.account_id, r.amount_minor, r.currency, r.direction, r.kind, r.status, r.counterparty, r.txn_time, r.txn_year_inferred, \
    r.received_at, r.processed_at, r.source, r.ingest_id, r.part_index, r.bank_reference, r.balance_after_minor, r.included_fee_minor, \
    r.note, r.transfer_group, r.related_record_id, r.transfer_party, r.settlement_minor, r.settlement_currency, r.category_id, r.order_group, \
    r.category_auto
    """
    /// 列表行：记录 + 账户 + 分类 + 配对转帐另一边的账户和金额 + 合并显示的手续费和退款
    static let rowColumns = columns + """
    , a.name, a.bank_name, a.last4, a.palette_id, a.currency, a.extra_currencies, a.card_type, \
    c.id, c.name, c.symbol, cp.name, pa.name, pa.bank_name, pa.last4, pa.card_type, \
    (SELECT f.amount_minor FROM records f WHERE r.part_index % 2 = 0 AND f.ingest_id = r.ingest_id AND f.part_index = r.part_index + 1 AND f.kind = 'fee' LIMIT 1), \
    (SELECT SUM(x.amount_minor) FROM records x WHERE x.related_record_id = r.id AND x.status = 'posted'), \
    a.deleted_at IS NOT NULL, pa.deleted_at IS NOT NULL, pr.amount_minor, pr.currency
    """
    static let rowFrom = """
    FROM records r JOIN accounts a ON a.id = r.account_id
    LEFT JOIN categories c ON c.id = r.category_id
    LEFT JOIN categories cp ON cp.id = c.parent_id
    LEFT JOIN records pr ON pr.id = (SELECT p.id FROM records p WHERE p.transfer_group = r.transfer_group AND p.id <> r.id LIMIT 1)
    LEFT JOIN accounts pa ON pa.id = pr.account_id
    """

    /// 支出、收入还是转帐，和 `LedgerRecord.entryType` 的规则一致
    public static let entryTypeSQL = """
    (CASE WHEN r.transfer_group IS NOT NULL OR r.transfer_party = 'own' OR r.kind IN ('repayment', 'deposit', 'withdrawal') THEN 'transfer' \
    WHEN r.direction = 'outflow' OR r.kind IN ('refund', 'reversal') THEN 'expense' ELSE 'income' END)
    """

    static func map(_ row: SQLiteConnection.Row) -> LedgerRecord {
        LedgerRecord(
            id: row.string(0), accountID: row.string(1), amountMinor: row.int(2), currency: CurrencyCode(row.string(3)),
            direction: FlowDirection(rawValue: row.string(4)) ?? .outflow, kind: TransactionKind(rawValue: row.string(5)) ?? .other,
            status: SettlementStatus(rawValue: row.string(6)) ?? .posted, counterparty: row.optionalString(7),
            transactionTime: row.optionalString(8).flatMap { WallClockCodec.decode($0, yearInferred: row.bool(9)) },
            receivedAt: row.optionalDate(10), processedAt: row.date(11), source: SourceKind(rawValue: row.string(12)) ?? .other,
            ingestID: row.string(13), partIndex: Int(row.int(14)), bankReference: row.optionalString(15),
            balanceAfterMinor: row.optionalInt(16), includedFeeMinor: row.optionalInt(17), note: row.string(18),
            transferGroupID: row.optionalString(19), relatedRecordID: row.optionalString(20),
            transferParty: row.optionalString(21).flatMap(TransferParty.init(rawValue:)),
            chargeCurrency: row.optionalString(23).map { CurrencyCode($0) }, settlementMinor: row.optionalInt(22),
            categoryID: row.optionalString(24), orderGroupID: row.optionalString(25), categoryAuto: row.bool(26)
        )
    }

    static func mapRow(_ row: SQLiteConnection.Row) -> RecordRow {
        let primary = CurrencyCode(row.string(31))
        let currencies = [primary] + Account.normalizedExtras(AccountDAO.decodeCurrencies(row.string(32)), primary: primary)
        let category = row.optionalString(34).map { id in
            CategoryLabel(id: id, name: row.string(35), symbol: row.string(36), parentName: row.optionalString(37))
        }
        let peer = row.optionalString(38).map { name in
            AccountLabel(
                name: name, bankName: row.string(39), last4: row.string(40), cardType: CardType(rawValue: row.string(41)) ?? .other, deleted: row.bool(45)
            )
        }
        return RecordRow(
            record: map(row), accountName: row.string(27), bankName: row.string(28), last4: row.string(29), paletteID: row.string(30),
            accountCurrencies: currencies, cardType: CardType(rawValue: row.string(33)) ?? .other, accountDeleted: row.bool(44),
            category: category, peer: peer,
            peerMoney: row.optionalInt(46).flatMap { minor in row.optionalString(47).map { Money(minorUnits: minor, currency: CurrencyCode($0)) } },
            feeMinor: row.optionalInt(42), refundedMinor: row.optionalInt(43)
        )
    }

    /// 插入一条记录。`dedupe_key` 冲突时返回 false（说明是重复），不抛错。
    public static func insertIfAbsent(_ db: SQLiteConnection, _ r: LedgerRecord, dedupeKey: String, now: Date) throws -> Bool {
        let changed = try db.run(
            """
            INSERT OR IGNORE INTO records (id, account_id, amount_minor, currency, direction, kind, status, counterparty, txn_time, \
            txn_year_inferred, received_at, processed_at, effective_at, source, ingest_id, part_index, bank_reference, balance_after_minor, \
            included_fee_minor, note, transfer_group, related_record_id, transfer_party, settlement_minor, settlement_currency, category_id, \
            order_group, category_auto, dedupe_key, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                r.id, r.accountID, r.amountMinor, r.currency.rawValue, r.direction.rawValue, r.kind.rawValue, r.status.rawValue,
                r.counterparty, r.transactionTime.map(WallClockCodec.encode), r.transactionTime?.yearInferred ?? false,
                r.receivedAt, r.processedAt, r.effectiveAt, r.source.rawValue, r.ingestID, r.partIndex, r.bankReference,
                r.balanceAfterMinor, r.includedFeeMinor, r.note, r.transferGroupID, r.relatedRecordID, r.transferParty?.rawValue,
                r.settlementMinor, r.chargeCurrency?.rawValue, r.categoryID, r.orderGroupID, r.categoryAuto, dedupeKey, now,
            ]
        )
        return changed > 0
    }

    /// 用户修改后的记录：写回能改的列（来源、原文、结算状态、合单不变）
    @discardableResult
    public static func update(_ db: SQLiteConnection, _ r: LedgerRecord) throws -> Bool {
        try db.run(
            """
            UPDATE records SET account_id = ?, amount_minor = ?, currency = ?, direction = ?, kind = ?, counterparty = ?, txn_time = ?, \
            txn_year_inferred = ?, received_at = ?, effective_at = ?, note = ?, transfer_group = ?, transfer_party = ?, \
            settlement_minor = ?, settlement_currency = ?, category_id = ?, category_auto = ? WHERE id = ?
            """,
            [
                r.accountID, r.amountMinor, r.currency.rawValue, r.direction.rawValue, r.kind.rawValue, r.counterparty,
                r.transactionTime.map(WallClockCodec.encode), r.transactionTime?.yearInferred ?? false, r.receivedAt, r.effectiveAt,
                r.note, r.transferGroupID, r.transferParty?.rawValue, r.settlementMinor, r.chargeCurrency?.rawValue,
                r.categoryID, r.categoryAuto, r.id,
            ]
        ) > 0
    }

    /// 删除一条记录和指向它的引用。通知本身（指纹）保留，同一条通知再来不会重新记上
    @discardableResult
    public static func delete(_ db: SQLiteConnection, id: String) throws -> Bool {
        guard let record = try find(db, id: id) else { return false }
        try db.run("DELETE FROM record_evidence WHERE record_id = ?", [id])
        try db.run("UPDATE records SET related_record_id = NULL WHERE related_record_id = ?", [id])
        try db.run("UPDATE balance_observations SET record_id = NULL WHERE record_id = ?", [id])
        try db.run("UPDATE pending_items SET duplicate_of_record_id = NULL WHERE duplicate_of_record_id = ?", [id])
        try db.run("DELETE FROM records WHERE id = ?", [id])
        // 配对的内部转账只剩另一边：不再算内部转账（手动合成的回到合成前的样子）
        if let group = record.transferGroupID, try db.scalarInt("SELECT COUNT(*) FROM records WHERE transfer_group = ?", [group]) < 2 {
            try dissolveTransferGroup(db, group: group)
        }
        if let group = record.orderGroupID { try clearOrderGroupIfAlone(db, group: group) }
        return true
    }

    // MARK: 分类与合单

    /// 设置分类（nil 为待分类）。`auto`：按学到的规律自动归的
    public static func setCategory(_ db: SQLiteConnection, ids: [String], categoryID: String?, auto: Bool = false) throws {
        for id in ids { try db.run("UPDATE records SET category_id = ?, category_auto = ? WHERE id = ?", [categoryID, auto, id]) }
    }

    /// 分类删除或合并：原来记在这些分类上的流水改记到 `to`（nil 为待分类，不再算自动归类）。
    /// 合成转帐的记着的合成前的分类也一起改，拆开时回到改过的分类
    public static func reassignCategory(_ db: SQLiteConnection, from ids: [String], to: String?) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            "UPDATE records SET category_id = ?, category_auto = category_auto AND ? IS NOT NULL WHERE category_id IN (\(placeholders))",
            ([to, to] as [SQLBindable]) + ids.map { $0 as SQLBindable }
        )
        try db.run(
            """
            UPDATE records SET merged_category_id = ?, merged_category_auto = merged_category_auto AND ? IS NOT NULL \
            WHERE merged_category_id IN (\(placeholders))
            """,
            ([to, to] as [SQLBindable]) + ids.map { $0 as SQLBindable }
        )
    }

    /// 已经有分类的流水，从早到晚（回放给学习、分类建议体检用）。`includingAuto` 为 false 时不含自动归的，那不是用户选的
    public static func categorized(_ db: SQLiteConnection, includingAuto: Bool = false) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r WHERE r.status = 'posted' AND r.category_id IS NOT NULL\(includingAuto ? "" : " AND r.category_auto = 0") \
            ORDER BY r.effective_at, r.id
            """,
            [], map
        )
    }

    /// 全部流水，从早到晚（导出用）
    public static func allRows(_ db: SQLiteConnection) throws -> [RecordRow] {
        try db.query("SELECT \(rowColumns) \(rowFrom) ORDER BY r.effective_at, r.id", [], mapRow)
    }

    /// 最近 `recent` 笔里用得最多的分类，多的在前。通知写明的（手续费、扣息、工资、利息）和退款不算，那不是用户选的
    public static func frequentCategories(_ db: SQLiteConnection, type: CategoryType, recent: Int = 200) throws -> [String] {
        try db.query(
            """
            SELECT category_id FROM (
                SELECT r.category_id, r.effective_at FROM records r JOIN categories c ON c.id = r.category_id
                WHERE r.status = 'posted' AND c.type = ?
                    AND r.kind NOT IN ('fee', 'interestCharge', 'salary', 'interestIncome', 'refund', 'reversal')
                ORDER BY r.effective_at DESC, r.id DESC LIMIT ?
            ) GROUP BY category_id ORDER BY COUNT(*) DESC, MAX(effective_at) DESC, category_id
            """,
            [type.rawValue, recent]
        ) { $0.string(0) }
    }

    /// 待分类：已入账的支出、收入还没有分类（合成一单的只留一行）
    static let uncategorizedFilter = """
    r.status = 'posted' AND r.category_id IS NULL AND \(entryTypeSQL) IN ('expense', 'income') AND NOT \(orderMemberHidden)
    """

    public static func uncategorized(_ db: SQLiteConnection, limit: Int = 200) throws -> [RecordRow] {
        try db.query(
            "SELECT \(rowColumns) \(rowFrom) WHERE \(uncategorizedFilter) ORDER BY r.effective_at DESC, r.id DESC LIMIT ?",
            [limit], mapRow
        )
    }

    public static func uncategorizedCount(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM records r WHERE \(uncategorizedFilter)"))
    }

    public static func setOrderGroup(_ db: SQLiteConnection, ids: [String], group: String) throws {
        for id in ids { try db.run("UPDATE records SET order_group = ? WHERE id = ?", [group, id]) }
    }

    public static func clearOrderGroup(_ db: SQLiteConnection, group: String) throws {
        try db.run("UPDATE records SET order_group = NULL WHERE order_group = ?", [group])
    }

    /// 这几笔从合成的一单里拆出去
    public static func leaveOrderGroup(_ db: SQLiteConnection, ids: [String]) throws {
        for id in ids { try db.run("UPDATE records SET order_group = NULL WHERE id = ?", [id]) }
    }

    /// 合成的一单只剩一笔：不再是合单
    public static func clearOrderGroupIfAlone(_ db: SQLiteConnection, group: String) throws {
        if try db.scalarInt("SELECT COUNT(*) FROM records WHERE order_group = ?", [group]) < 2 {
            try clearOrderGroup(db, group: group)
        }
    }

    /// 同一单的几笔，按时间先后
    public static func inOrderGroup(_ db: SQLiteConnection, groups: [String]) throws -> [RecordRow] {
        guard !groups.isEmpty else { return [] }
        let placeholders = groups.map { _ in "?" }.joined(separator: ", ")
        return try db.query(
            "SELECT \(rowColumns) \(rowFrom) WHERE r.order_group IN (\(placeholders)) ORDER BY r.effective_at, r.id",
            groups.map { $0 as SQLBindable }, mapRow
        )
    }

    /// 关联到这一笔的退款。了结的冻结也关联到完成扣款，它不是退款
    public static func refunds(_ db: SQLiteConnection, of recordID: String) throws -> [RecordRow] {
        try db.query("SELECT \(rowColumns) \(rowFrom) WHERE r.related_record_id = ? AND r.status = 'posted' ORDER BY r.effective_at", [recordID], mapRow)
    }

    /// 同一条通知拆出的手续费
    public static func splitFee(_ db: SQLiteConnection, of record: LedgerRecord) throws -> RecordRow? {
        guard record.partIndex % 2 == 0 else { return nil }
        return try db.queryOne(
            "SELECT \(rowColumns) \(rowFrom) WHERE r.ingest_id = ? AND r.part_index = ? AND r.kind = 'fee'",
            [record.ingestID, record.partIndex + 1], mapRow
        )
    }

    /// 时间范围内已入账的流水（手动记账查重、合成一单的候选）
    public static func postedRows(_ db: SQLiteConnection, from: Date, to: Date, limit: Int = 200) throws -> [RecordRow] {
        try db.query(
            "SELECT \(rowColumns) \(rowFrom) WHERE r.status = 'posted' AND r.effective_at >= ? AND r.effective_at <= ? ORDER BY r.effective_at DESC LIMIT ?",
            [from, to, limit], mapRow
        )
    }

    public static func clearTransferGroup(_ db: SQLiteConnection, group: String) throws {
        try db.run("UPDATE records SET transfer_group = NULL WHERE transfer_group = ?", [group])
    }

    // MARK: 合成转帐

    /// 一笔流出和另一个账户的一笔流入手动合成转帐：两笔共用转帐组 `group`，交易性质改成 `outKind` / `inKind`，
    /// 不再有分类和转账对方（和自动配对的转帐一样）。合成前的交易性质、对方、分类记在 `merged_*` 里，拆开时改回去
    public static func mergeIntoTransfer(
        _ db: SQLiteConnection, outflowID: String, outKind: TransactionKind, inflowID: String, inKind: TransactionKind, group: String
    ) throws {
        for (id, kind) in [(outflowID, outKind), (inflowID, inKind)] {
            try db.run(
                """
                UPDATE records SET merged_kind = kind, merged_party = transfer_party, merged_category_id = category_id, \
                merged_category_auto = category_auto, kind = ?, transfer_party = NULL, category_id = NULL, category_auto = 0, \
                transfer_group = ? WHERE id = ?
                """,
                [kind.rawValue, group, id]
            )
        }
    }

    /// 这一笔是手动合成的转帐（拆开能回到合成前）
    public static func isMergedTransfer(_ db: SQLiteConnection, id: String) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM records WHERE id = ? AND merged_kind IS NOT NULL", [id]) > 0
    }

    /// 转帐组拆开，不再配对。手动合成的回到合成前的交易性质、对方和分类（分类已经删掉的回到待分类）
    public static func dissolveTransferGroup(_ db: SQLiteConnection, group: String) throws {
        try db.run(
            """
            UPDATE records SET kind = merged_kind, transfer_party = merged_party, \
            category_id = (SELECT c.id FROM categories c WHERE c.id = records.merged_category_id), \
            category_auto = merged_category_auto AND EXISTS (SELECT 1 FROM categories c WHERE c.id = records.merged_category_id), \
            merged_kind = NULL, merged_party = NULL, merged_category_id = NULL, merged_category_auto = 0 \
            WHERE transfer_group = ? AND merged_kind IS NOT NULL
            """,
            [group]
        )
        try clearTransferGroup(db, group: group)
    }

    /// 只剩一笔的转帐组都拆开（导入时另一边这里本来就有、没有再加）
    public static func dissolveLoneTransferGroups(_ db: SQLiteConnection) throws {
        let groups = try db.query(
            "SELECT transfer_group FROM records WHERE transfer_group IS NOT NULL GROUP BY transfer_group HAVING COUNT(*) < 2", []
        ) { $0.string(0) }
        for group in groups { try dissolveTransferGroup(db, group: group) }
    }

    public static func idForDedupeKey(_ db: SQLiteConnection, _ key: String) throws -> String? {
        try db.queryOne("SELECT id FROM records WHERE dedupe_key = ?", [key]) { $0.string(0) }
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> LedgerRecord? {
        try db.queryOne("SELECT \(columns) FROM records r WHERE r.id = ?", [id], map)
    }

    public static func findRow(_ db: SQLiteConnection, id: String) throws -> RecordRow? {
        try db.queryOne("SELECT \(rowColumns) \(rowFrom) WHERE r.id = ?", [id], mapRow)
    }

    /// 首页：全部账户流水，按系统时间倒序，键集分页。
    /// 没配对到自己另一张卡、也还没确认对方的转账
    static let unconfirmedTransferFilter = "r.status = 'posted' AND r.kind IN ('transferIn', 'transferOut') AND r.transfer_group IS NULL AND r.transfer_party IS NULL"

    public static func unconfirmedTransfers(_ db: SQLiteConnection, limit: Int = 100) throws -> [RecordRow] {
        try db.query(
            "SELECT \(rowColumns) \(rowFrom) WHERE \(unconfirmedTransferFilter) ORDER BY r.effective_at DESC, r.id DESC LIMIT ?",
            [limit], mapRow
        )
    }

    /// 合成一单的几笔里，不是最晚那一笔的（首页只显示最晚那一笔，金额是整单的）
    static let orderMemberHidden = """
    (r.order_group IS NOT NULL AND EXISTS (SELECT 1 FROM records o WHERE o.order_group = r.order_group \
    AND (o.effective_at > r.effective_at OR (o.effective_at = r.effective_at AND o.id > r.id))))
    """
    /// 配对的转帐里转入的那一边（首页只显示转出那边，写成「招行 → 工行」）
    static let pairedInflowHidden = """
    (r.transfer_group IS NOT NULL AND r.direction = 'inflow' AND EXISTS (SELECT 1 FROM records p WHERE p.transfer_group = r.transfer_group AND p.id <> r.id))
    """
    /// 同一条通知拆出的手续费（合到那一笔下面显示）
    static let splitFeeHidden = """
    (r.kind = 'fee' AND r.part_index % 2 = 1 AND EXISTS (SELECT 1 FROM records m WHERE m.ingest_id = r.ingest_id AND m.part_index = r.part_index - 1))
    """

    public static func unconfirmedTransferCount(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM records r WHERE \(unconfirmedTransferFilter)"))
    }

    @discardableResult
    public static func setTransferParty(_ db: SQLiteConnection, id: String, party: TransferParty?) throws -> Bool {
        try db.run("UPDATE records SET transfer_party = ? WHERE id = ?", [party?.rawValue, id]) > 0
    }

    public static func page(_ db: SQLiteConnection, accountID: String?, before cursor: RecordCursor?, limit: Int) throws -> [RecordRow] {
        try page(db, filter: RecordFilter(accountID: accountID), before: cursor, limit: limit)
    }

    /// 按条件查流水，按系统时间倒序，键集分页。
    public static func page(_ db: SQLiteConnection, filter: RecordFilter, before cursor: RecordCursor?, limit: Int) throws -> [RecordRow] {
        var (conditions, values) = filterClauses(filter)
        if let cursor {
            conditions.append("(r.effective_at < ? OR (r.effective_at = ? AND r.id < ?))")
            values.append(cursor.effectiveAt)
            values.append(cursor.effectiveAt)
            values.append(cursor.id)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        values.append(limit)
        return try db.query(
            "SELECT \(rowColumns) \(rowFrom) \(whereClause) ORDER BY r.effective_at DESC, r.id DESC LIMIT ?",
            values, mapRow
        )
    }

    public static func count(_ db: SQLiteConnection, accountID: String? = nil) throws -> Int {
        try count(db, filter: RecordFilter(accountID: accountID))
    }

    public static func count(_ db: SQLiteConnection, filter: RecordFilter) throws -> Int {
        let (conditions, values) = filterClauses(filter)
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return Int(try db.scalarInt("SELECT COUNT(*) \(rowFrom) \(whereClause)", values))
    }

    /// 账户持有 `column` 这个币种（主币种或其他币种之一）
    static func held(_ column: String) -> String {
        "(\(column) = a.currency OR instr(',' || a.extra_currencies || ',', ',' || \(column) || ',') > 0)"
    }

    /// 这笔从账户的哪个币种扣款（入账），和 `LedgerRecord.chargedCurrency(in:)` 一样：
    /// 记下的扣款币种（账户还有它时）> 这笔自己的币种（账户有时）> 主币种
    static let chargedCurrency = """
    (CASE WHEN r.settlement_currency IS NOT NULL AND \(held("r.settlement_currency")) THEN r.settlement_currency WHEN \(held("r.currency")) THEN r.currency ELSE a.currency END)
    """

    /// 没有小数、三位小数的币种：按关键字找金额时区分小数位数
    static let zeroDecimalCodes = CurrencyCode.supported.filter { $0.minorUnitExponent == 0 }.map(\.rawValue)
    static let threeDecimalCodes = CurrencyCode.supported.filter { $0.minorUnitExponent == 3 }.map(\.rawValue)

    static func filterClauses(_ filter: RecordFilter) -> ([String], [SQLBindable]) {
        var conditions: [String] = []
        var values: [SQLBindable] = []
        if let accountID = filter.accountID {
            conditions.append("r.account_id = ?")
            values.append(accountID)
        }
        if let currency = filter.currency {
            // 从这个币种扣款（入账）的：包括账户没有的币种按主币种扣的、余额不够换成它扣的
            conditions.append("\(chargedCurrency) = ?")
            values.append(currency.rawValue)
        }
        if let direction = filter.direction {
            conditions.append("r.direction = ?")
            values.append(direction.rawValue)
        }
        if let from = filter.from {
            conditions.append("r.effective_at >= ?")
            values.append(from)
        }
        if let to = filter.to {
            conditions.append("r.effective_at < ?")
            values.append(to)
        }
        if let type = filter.entryType {
            conditions.append("\(entryTypeSQL) = ?")
            values.append(type.rawValue)
        }
        if let categoryID = filter.categoryID {
            if categoryID == RecordFilter.uncategorized {
                conditions.append("(r.category_id IS NULL AND \(entryTypeSQL) IN ('expense', 'income'))")
            } else {
                conditions.append("(r.category_id = ? OR r.category_id IN (SELECT id FROM categories WHERE parent_id = ?))")
                values.append(categoryID)
                values.append(categoryID)
            }
        }
        if filter.feed {
            conditions.append("r.status = 'posted'")
            conditions.append("NOT \(pairedInflowHidden)")
            conditions.append("NOT \(orderMemberHidden)")
        }
        if filter.mergeFees {
            conditions.append("NOT \(splitFeeHidden)")
        }
        for word in filter.text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let pattern = "%" + escapeLike(word) + "%"
            var any = ["r.counterparty", "r.note", "a.name", "a.bank_name", "a.last4", "c.name", "cp.name", "pa.name", "pa.bank_name"]
                .map { "\($0) LIKE ? ESCAPE '\\'" }
            values += Array(repeating: pattern as SQLBindable, count: any.count)
            let kinds = TransactionKind.allCases.filter { $0.displayName.contains(word) }
            if !kinds.isEmpty {
                any.append("r.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
                values += kinds.map(\.rawValue) as [SQLBindable]
            }
            let types = EntryType.allCases.filter { $0.displayName.contains(word) }
            if !types.isEmpty {
                any.append("\(entryTypeSQL) IN (\(types.map { _ in "?" }.joined(separator: ", ")))")
                values += types.map(\.rawValue) as [SQLBindable]
            }
            for range in amountRanges(word) {
                let codes: [String]
                let test: String
                switch range.exponent {
                case 0: (codes, test) = (zeroDecimalCodes, "IN")
                case 3: (codes, test) = (threeDecimalCodes, "IN")
                default: (codes, test) = (zeroDecimalCodes + threeDecimalCodes, "NOT IN")
                }
                let list = codes.map { _ in "?" }.joined(separator: ", ")
                // 交易金额，或者按主币种的实际扣款（外币消费记得扣了多少人民币也能找到）
                for (amount, currency) in [("r.amount_minor", "r.currency"), ("r.settlement_minor", "r.settlement_currency")] {
                    any.append("(\(amount) BETWEEN ? AND ? AND \(currency) \(test) (\(list)))")
                    values.append(range.low)
                    values.append(range.high)
                    values += codes.map { $0 as SQLBindable }
                }
            }
            conditions.append("(" + any.joined(separator: " OR ") + ")")
        }
        return (conditions, values)
    }

    static func escapeLike(_ text: String) -> String {
        var result = ""
        for char in text {
            if char == "\\" || char == "%" || char == "_" { result.append("\\") }
            result.append(char)
        }
        return result
    }

    /// 关键字像金额时找的范围（按 0、2、3 位小数换算成最小单位）。写了小数的按原样找；
    /// 只写整数的是记不清的「大概多少」：上下差 10%，至少差 1（38 找 34.20～41.80，5 找 4～6，1000 找 900～1100）
    static func amountRanges(_ word: String) -> [(exponent: Int, low: Int64, high: Int64)] {
        let approximate = amountFraction(word).isEmpty
        return amountMinors(word).map { exponent, minor in
            guard approximate else { return (exponent, minor, minor) }
            var unit: Int64 = 1
            for _ in 0..<exponent { unit *= 10 }
            let tolerance = max(unit, minor / 10)
            return (exponent, max(0, minor - tolerance), minor + tolerance)
        }
    }

    /// 金额关键字的小数部分（「12,50」这种逗号小数也算）；没写小数时为空
    private static func amountFraction(_ word: String) -> String {
        let text = normalizedAmount(word)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    /// 「12,50」（只有一个逗号、后面不超过两位）当作小数点，其余的逗号是千位分隔
    private static func normalizedAmount(_ word: String) -> String {
        var text = word
        if text.contains(","), !text.contains("."), let last = text.split(separator: ",").last, last.count <= 2, text.split(separator: ",").count == 2 {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        return text.replacingOccurrences(of: ",", with: "")
    }

    /// 关键字像金额（38、38.5、1,234.56）时，按 0、2、3 位小数换算成最小单位；不像金额时为空
    static func amountMinors(_ word: String) -> [(exponent: Int, minor: Int64)] {
        let text = normalizedAmount(word)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let integer = parts.first, !integer.isEmpty, integer.count <= 12,
              integer.allSatisfy({ $0.isASCII && $0.isNumber }) else { return [] }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }), fraction.count <= 3, parts.count == 1 || !fraction.isEmpty,
              let whole = Int64(integer) else { return [] }
        var result: [(exponent: Int, minor: Int64)] = []
        for exponent in [0, 2, 3] {
            // 小数位比币种多：多出来的必须都是 0
            let kept = String(fraction.prefix(exponent))
            guard fraction.dropFirst(exponent).allSatisfy({ $0 == "0" }) else { continue }
            var scale: Int64 = 1
            for _ in 0..<exponent { scale *= 10 }
            let padded = kept + String(repeating: "0", count: exponent - kept.count)
            result.append((exponent: exponent, minor: whole * scale + (Int64(padded) ?? 0)))
        }
        return result
    }

    public static func updateNote(_ db: SQLiteConnection, id: String, note: String) throws -> Bool {
        try db.run("UPDATE records SET note = ? WHERE id = ?", [note, id]) > 0
    }

    public static func setTransferGroup(_ db: SQLiteConnection, ids: [String], group: String) throws {
        for id in ids { try db.run("UPDATE records SET transfer_group = ? WHERE id = ?", [group, id]) }
    }

    public static func setRelated(_ db: SQLiteConnection, id: String, relatedID: String) throws {
        try db.run("UPDATE records SET related_record_id = ? WHERE id = ?", [relatedID, id])
    }

    public static func clearRelated(_ db: SQLiteConnection, id: String) throws {
        try db.run("UPDATE records SET related_record_id = NULL WHERE id = ?", [id])
    }

    /// 手动关联退款的候选：时间范围内已入账、同一币种的支出。`refunds` 为 false 时是原交易（流出，金额不小于 `amount`），
    /// 为 true 时是还没关联到别的交易的退款（流入，金额不大于 `amount`）。新的在前
    public static func refundLinkRows(
        _ db: SQLiteConnection, refunds: Bool, currency: CurrencyCode, amount: Int64, from: Date, to: Date, excluding id: String, limit: Int = 300
    ) throws -> [RecordRow] {
        let side = refunds
            ? "r.direction = 'inflow' AND r.related_record_id IS NULL AND r.amount_minor <= ?"
            : "r.direction = 'outflow' AND r.amount_minor >= ?"
        return try db.query(
            """
            SELECT \(rowColumns) \(rowFrom) WHERE r.status = 'posted' AND \(entryTypeSQL) = 'expense' AND \(side)
              AND r.currency = ? AND r.effective_at >= ? AND r.effective_at <= ? AND r.id <> ?
            ORDER BY r.effective_at DESC LIMIT ?
            """,
            [amount, currency.rawValue, from, to, id, limit], mapRow
        )
    }

    public static func setStatus(_ db: SQLiteConnection, id: String, status: SettlementStatus) throws {
        try db.run("UPDATE records SET status = ? WHERE id = ?", [status.rawValue, id])
    }

    /// 这张卡上还在冻结中的流出
    public static func holds(_ db: SQLiteConnection, accountID: String) throws -> [LedgerRecord] {
        try db.query("SELECT \(columns) FROM records r WHERE r.account_id = ? AND r.status = 'hold' AND r.direction = 'outflow'", [accountID], map)
    }

    /// 金额、币种、方向一致的候选记录（用于跨来源重复检测和内部转账配对）。
    public static func candidates(
        _ db: SQLiteConnection, amountMinor: Int64, currency: CurrencyCode, direction: FlowDirection,
        effectiveFrom: Date, effectiveTo: Date, excludingIngest: String
    ) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r
            WHERE r.amount_minor = ? AND r.currency = ? AND r.direction = ? AND r.effective_at BETWEEN ? AND ? AND r.ingest_id <> ?
            ORDER BY r.effective_at
            """,
            [amountMinor, currency.rawValue, direction.rawValue, effectiveFrom, effectiveTo, excludingIngest], map
        )
    }

    public static func inGroup(_ db: SQLiteConnection, group: String) throws -> [LedgerRecord] {
        try db.query("SELECT \(columns) FROM records r WHERE r.transfer_group = ?", [group], map)
    }

    /// 退款关联：同账户、同交易对方、金额不小于退款的较早流出记录。
    public static func refundOriginCandidates(_ db: SQLiteConnection, accountID: String, counterparty: String, minAmount: Int64, currency: CurrencyCode, before: Date, after: Date) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r
            WHERE r.account_id = ? AND r.counterparty = ? AND r.direction = 'outflow' AND r.status = 'posted'
              AND r.currency = ? AND r.amount_minor >= ? AND r.effective_at BETWEEN ? AND ?
            """,
            [accountID, counterparty, currency.rawValue, minAmount, after, before], map
        )
    }

    /// 推算余额用的流水：这张卡已入账的，和还在冻结中的流出（算可用余额）
    public static func forBalance(_ db: SQLiteConnection, accountID: String) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r
            WHERE r.account_id = ? AND (r.status = 'posted' OR (r.status = 'hold' AND r.direction = 'outflow')) ORDER BY r.effective_at
            """,
            [accountID], map
        )
    }

    public static func addEvidence(_ db: SQLiteConnection, recordID: String, ingestID: String, source: SourceKind, at date: Date) throws {
        try db.run(
            "INSERT OR IGNORE INTO record_evidence (record_id, ingest_id, source, added_at) VALUES (?, ?, ?, ?)",
            [recordID, ingestID, source.rawValue, date]
        )
    }

    public static func evidence(_ db: SQLiteConnection, recordID: String) throws -> [RecordEvidence] {
        try db.query(
            """
            SELECT i.id, i.source, i.sender, i.received_at, i.processed_at, i.raw_text
            FROM record_evidence e JOIN ingests i ON i.id = e.ingest_id WHERE e.record_id = ? ORDER BY i.processed_at
            """,
            [recordID]
        ) { row in
            RecordEvidence(ingestID: row.string(0), source: SourceKind(rawValue: row.string(1)) ?? .other, sender: row.optionalString(2), receivedAt: row.optionalDate(3), processedAt: row.date(4), rawText: row.optionalString(5))
        }
    }

    /// 每笔流水的全部来源通知（同一笔的短信、邮件合并后都在这里），按加上的先后（导出用）
    public static func allEvidence(_ db: SQLiteConnection) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (record, ingest) in try db.query("SELECT record_id, ingest_id FROM record_evidence ORDER BY added_at, rowid", [], { ($0.string(0), $0.string(1)) }) {
            result[record, default: []].append(ingest)
        }
        return result
    }

    /// 统计用：时间段内全部记录（只取聚合需要的列由调用方处理）。
    public static func inRange(_ db: SQLiteConnection, from: Date, to: Date) throws -> [LedgerRecord] {
        try db.query("SELECT \(columns) FROM records r WHERE r.effective_at >= ? AND r.effective_at < ?", [from, to], map)
    }
}

public enum IngestDAO {
    public static func exists(_ db: SQLiteConnection, fingerprint: String) throws -> String? {
        try db.queryOne("SELECT id FROM ingests WHERE fingerprint = ?", [fingerprint]) { $0.string(0) }
    }

    public static func insert(
        _ db: SQLiteConnection, id: String, fingerprint: String, request: IngestRequest, processedAt: Date,
        rawText: String?, rawPurgeAfter: Date?, classification: MessageClassification, outcome: IngestOutcome,
        detail: String, parserVersion: Int
    ) throws {
        try db.run(
            """
            INSERT INTO ingests (id, fingerprint, source, sender, subject, received_at, message_id, bound_account_id, processed_at, raw_text, \
            raw_purge_after, classification, outcome, detail, parser_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                id, fingerprint, request.source.rawValue, request.sender, request.subject, request.receivedAt, request.messageID,
                request.boundAccountID, processedAt, rawText, rawPurgeAfter, classification.rawValue, outcome.rawValue, detail, parserVersion,
            ]
        )
    }

    public static func updateResult(_ db: SQLiteConnection, id: String, classification: MessageClassification, outcome: IngestOutcome, detail: String, rawPurgeAfter: Date?) throws {
        try db.run(
            "UPDATE ingests SET classification = ?, outcome = ?, detail = ?, raw_purge_after = ? WHERE id = ?",
            [classification.rawValue, outcome.rawValue, detail, rawPurgeAfter, id]
        )
    }

    /// 手动记的一笔也记一条输入（流水要有来源），不写正文、不进接收日志
    public static func insertManual(_ db: SQLiteConnection, id: String, receivedAt: Date, processedAt: Date) throws {
        try db.run(
            """
            INSERT INTO ingests (id, fingerprint, source, received_at, processed_at, classification, outcome, detail, parser_version) \
            VALUES (?, ?, ?, ?, ?, ?, ?, '', 0)
            """,
            [id, "manual|" + id, SourceKind.manual.rawValue, receivedAt, processedAt, MessageClassification.transaction.rawValue, IngestOutcome.recorded.rawValue]
        )
    }

    static let logColumns = "id, source, sender, subject, received_at, processed_at, classification, outcome, detail, raw_text, bound_account_id"

    static func mapLog(_ row: SQLiteConnection.Row) -> IngestLogEntry {
        IngestLogEntry(
            id: row.string(0), source: SourceKind(rawValue: row.string(1)) ?? .other, sender: row.optionalString(2), subject: row.optionalString(3),
            receivedAt: row.optionalDate(4), processedAt: row.date(5), classification: MessageClassification(rawValue: row.string(6)) ?? .unrecognized,
            outcome: IngestOutcome(rawValue: row.string(7)) ?? .filtered, detail: row.string(8), rawText: row.optionalString(9), boundAccountID: row.optionalString(10)
        )
    }

    public static func recent(_ db: SQLiteConnection, limit: Int) throws -> [IngestLogEntry] {
        try db.query("SELECT \(logColumns) FROM ingests WHERE source <> 'manual' ORDER BY processed_at DESC LIMIT ?", [limit], mapLog)
    }

    /// 收到过的全部通知，从早到晚（导出用）。手动记的一笔也有一条输入，但没有内容，不算
    public static func all(_ db: SQLiteConnection) throws -> [IngestLogEntry] {
        try db.query("SELECT \(logColumns) FROM ingests WHERE source <> 'manual' ORDER BY processed_at, id", [], mapLog)
    }

    public static func meta(_ db: SQLiteConnection, id: String) throws -> (source: SourceKind, sender: String?, receivedAt: Date?, processedAt: Date, rawText: String?)? {
        try db.queryOne("SELECT source, sender, received_at, processed_at, raw_text FROM ingests WHERE id = ?", [id]) { row in
            (SourceKind(rawValue: row.string(0)) ?? .other, row.optionalString(1), row.optionalDate(2), row.date(3), row.optionalString(4))
        }
    }

    /// 清理到期的原始内容：只清空正文，保留指纹（用于幂等去重）和处理结果。
    @discardableResult
    public static func purgeRaw(_ db: SQLiteConnection, now: Date) throws -> Int {
        try db.run(
            """
            UPDATE ingests SET raw_text = NULL WHERE raw_text IS NOT NULL AND raw_purge_after IS NOT NULL AND raw_purge_after <= ?
              AND id NOT IN (SELECT ingest_id FROM pending_items WHERE status = 'open')
            """,
            [now]
        )
    }
}

public enum PendingDAO {
    static let select = """
    SELECT p.id, p.ingest_id, p.reason, p.draft_json, p.candidate_account_ids, p.duplicate_of_record_id, p.status, p.created_at, \
    i.source, i.sender, i.received_at, i.raw_text, p.part_index
    FROM pending_items p JOIN ingests i ON i.id = p.ingest_id
    """

    static func map(_ row: SQLiteConnection.Row) -> PendingItem {
        let draft = row.optionalString(3).flatMap { try? JSONDecoder().decode(EventDraft.self, from: Data($0.utf8)) }
        let candidates = row.string(4).split(separator: ",").map(String.init)
        return PendingItem(
            id: row.string(0), ingestID: row.string(1), reason: PendingReason(rawValue: row.string(2)) ?? .unrecognized, draft: draft,
            candidateAccountIDs: candidates, duplicateOfRecordID: row.optionalString(5), status: PendingStatus(rawValue: row.string(6)) ?? .open,
            createdAt: row.date(7), source: SourceKind(rawValue: row.string(8)) ?? .other, sender: row.optionalString(9),
            receivedAt: row.optionalDate(10), rawText: row.optionalString(11)
        )
    }

    public static func insert(_ db: SQLiteConnection, id: String, ingestID: String, partIndex: Int, reason: PendingReason, draft: EventDraft?, candidates: [String], duplicateOf: String?, now: Date) throws {
        let json = try draft.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.run(
            "INSERT INTO pending_items (id, ingest_id, part_index, reason, draft_json, candidate_account_ids, duplicate_of_record_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?)",
            [id, ingestID, partIndex, reason.rawValue, json, candidates.joined(separator: ","), duplicateOf, now]
        )
    }

    public static func open(_ db: SQLiteConnection) throws -> [PendingItem] {
        try db.query(select + " WHERE p.status = 'open' ORDER BY p.created_at DESC", [], map)
    }

    /// 全部待处理，包括已经记入、忽略的，从早到晚（导出用）
    public static func all(_ db: SQLiteConnection) throws -> [PendingItem] {
        try db.query(select + " ORDER BY p.created_at, p.id", [], map)
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> PendingItem? {
        try db.queryOne(select + " WHERE p.id = ?", [id], map)
    }

    public static func partIndex(_ db: SQLiteConnection, id: String) throws -> Int {
        Int(try db.scalarInt("SELECT part_index FROM pending_items WHERE id = ?", [id]))
    }

    public static func openCount(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM pending_items WHERE status = 'open'"))
    }

    public static func resolve(_ db: SQLiteConnection, id: String, status: PendingStatus, at date: Date) throws -> Bool {
        try db.run("UPDATE pending_items SET status = ?, resolved_at = ? WHERE id = ? AND status = 'open'", [status.rawValue, date, id]) > 0
    }

    /// 同一条通知里其他「金额有歧义」的候选标为已忽略。交易和它拆出的手续费共用 `part_index / 2`，手续费保留。
    public static func ignoreOtherAmounts(_ db: SQLiteConnection, ingestID: String, keepingPart part: Int, at date: Date) throws {
        try db.run(
            "UPDATE pending_items SET status = 'ignored', resolved_at = ? WHERE ingest_id = ? AND status = 'open' AND reason = ? AND part_index / 2 <> ?",
            [date, ingestID, PendingReason.ambiguousAmount.rawValue, part / 2]
        )
    }

    /// 给这条通知新增一笔时用的序号：比已有的待处理和流水都大，偶数（奇数留给拆出的手续费）
    public static func nextPartIndex(_ db: SQLiteConnection, ingestID: String) throws -> Int {
        let maxPart = try db.scalarInt(
            "SELECT MAX(COALESCE((SELECT MAX(part_index) FROM pending_items WHERE ingest_id = ?), -1), COALESCE((SELECT MAX(part_index) FROM records WHERE ingest_id = ?), -1))",
            [ingestID, ingestID]
        )
        return Int(maxPart + 2) / 2 * 2
    }

    /// 这条通知是否已经有入账的流水
    public static func ingestHasRecords(_ db: SQLiteConnection, ingestID: String) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM records WHERE ingest_id = ?", [ingestID]) > 0
    }
}

public enum BalanceDAO {
    public static func insert(_ db: SQLiteConnection, id: String, observation o: BalanceObservation, ingestID: String) throws {
        try db.run(
            "INSERT INTO balance_observations (id, account_id, amount_minor, currency, order_key, txn_time, observed_at, ingest_id, record_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [id, o.accountID, o.amountMinor, o.currency.rawValue, o.orderKey, o.transactionTime.map(WallClockCodec.encode), o.observedAt, ingestID, o.recordID]
        )
    }

    static let columns = "account_id, amount_minor, currency, order_key, txn_time, observed_at, record_id"

    static func map(_ row: SQLiteConnection.Row) -> BalanceObservation {
        BalanceObservation(
            accountID: row.string(0), amountMinor: row.int(1), currency: CurrencyCode(row.string(2)), orderKey: row.string(3),
            transactionTime: row.optionalString(4).flatMap { WallClockCodec.decode($0, yearInferred: false) }, observedAt: row.date(5), recordID: row.optionalString(6)
        )
    }

    /// 某币种最新的银行余额：按通知内时间（order_key）排序，而不是按到达顺序，避免旧消息覆盖新余额。
    public static func latest(_ db: SQLiteConnection, accountID: String, currency: CurrencyCode) throws -> BalanceObservation? {
        try db.queryOne(
            "SELECT \(columns) FROM balance_observations WHERE account_id = ? AND currency = ? ORDER BY order_key DESC, observed_at DESC LIMIT 1",
            [accountID, currency.rawValue], map
        )
    }

    /// 银行通知里写过的全部余额，按账户、时间（导出用）
    public static func all(_ db: SQLiteConnection) throws -> [BalanceObservation] {
        try db.query("SELECT \(columns) FROM balance_observations ORDER BY account_id, order_key, observed_at", [], map)
    }

    /// 这张卡收到过银行余额的币种
    public static func currencies(_ db: SQLiteConnection, accountID: String) throws -> [CurrencyCode] {
        try db.query("SELECT DISTINCT currency FROM balance_observations WHERE account_id = ? ORDER BY currency", [accountID]) { CurrencyCode($0.string(0)) }
    }
}

public enum TemplateDAO {
    /// 新做的模板在前：同一条通知能被多个模板认出时，用最新的
    public static func all(_ db: SQLiteConnection) throws -> [MessageTemplate] {
        try db.query("SELECT id, name, pieces_json, kind, direction, created_at FROM message_templates ORDER BY created_at DESC, id", []) { row -> MessageTemplate? in
            guard let pieces = try? JSONDecoder().decode([TemplatePiece].self, from: Data(row.string(2).utf8)),
                  let kind = TransactionKind(rawValue: row.string(3)),
                  let direction = FlowDirection(rawValue: row.string(4)) else { return nil }
            return MessageTemplate(id: row.string(0), name: row.string(1), pieces: pieces, kind: kind, direction: direction, createdAt: row.date(5))
        }
        .compactMap { $0 }
    }

    /// 新模板插入；同一个标识已经有了就改写（编辑模板），添加时间不变，排序也不变
    public static func save(_ db: SQLiteConnection, _ t: MessageTemplate) throws {
        let json = String(decoding: try JSONEncoder().encode(t.pieces), as: UTF8.self)
        try db.run(
            """
            INSERT INTO message_templates (id, name, pieces_json, kind, direction, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, pieces_json = excluded.pieces_json, kind = excluded.kind, direction = excluded.direction
            """,
            [t.id, t.name, json, t.kind.rawValue, t.direction.rawValue, t.createdAt]
        )
    }

    @discardableResult
    public static func delete(_ db: SQLiteConnection, id: String) throws -> Bool {
        try db.run("DELETE FROM message_templates WHERE id = ?", [id]) > 0
    }
}

/// 每天的完整汇率表（快捷指令导入的数据源原样保存，不删减币种）。
public enum RateDAO {
    /// 保存一天的汇率。这一天已经有同样新或更新的下载时不覆盖，返回 false
    @discardableResult
    public static func save(_ db: SQLiteConnection, day: String, rates: ExchangeRates) throws -> Bool {
        if let fetched = try db.queryOne("SELECT fetched_at FROM exchange_rate_days WHERE day = ?", [day], { $0.date(0) }), fetched >= rates.fetchedAt {
            return false
        }
        try db.run(
            """
            INSERT INTO exchange_rate_days (day, base, updated_at, fetched_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET base = excluded.base, updated_at = excluded.updated_at, fetched_at = excluded.fetched_at
            """,
            [day, rates.base.rawValue, rates.updatedAt, rates.fetchedAt]
        )
        try db.run("DELETE FROM exchange_rates WHERE day = ?", [day])
        var table = rates.rates.filter { $0.value > 0 && $0.value.isFinite }
        table[rates.base.rawValue] = 1
        for (code, rate) in table {
            try db.run("INSERT OR REPLACE INTO exchange_rates (day, currency, rate) VALUES (?, ?, ?)", [day, code.uppercased(), rate])
        }
        return true
    }

    /// 有汇率的日期，从早到晚
    public static func days(_ db: SQLiteConnection) throws -> [String] {
        try db.query("SELECT day FROM exchange_rate_days ORDER BY day", []) { $0.string(0) }
    }

    /// 每天汇率表的基准币种和数据源的更新时间，从早到晚（导出用）
    public static func dayInfo(_ db: SQLiteConnection) throws -> [(day: String, base: String, updatedAt: Date)] {
        try db.query("SELECT day, base, updated_at FROM exchange_rate_days ORDER BY day", []) { (day: $0.string(0), base: $0.string(1), updatedAt: $0.date(2)) }
    }

    /// 某天全部币种的汇率（1 个基准可兑换的数量）
    public static func rates(_ db: SQLiteConnection, day: String) throws -> [String: Double] {
        var table: [String: Double] = [:]
        for (code, rate) in try db.query("SELECT currency, rate FROM exchange_rates WHERE day = ?", [day], { ($0.string(0), $0.double(1)) }) {
            table[code] = rate
        }
        return table
    }
}

/// 分类：大类和小类（最多两层）。默认的那套由迁移写入，之后全由用户管理。
public enum CategoryDAO {
    static let columns = "id, type, parent_id, name, symbol, sort_order, hidden, auto_key, locked"

    static func map(_ row: SQLiteConnection.Row) -> LedgerCategory {
        LedgerCategory(
            id: row.string(0), type: CategoryType(rawValue: row.string(1)) ?? .expense, parentID: row.optionalString(2),
            name: row.string(3), symbol: row.string(4), sortOrder: Int(row.int(5)), hidden: row.bool(6),
            autoKey: row.optionalString(7), locked: row.bool(8)
        )
    }

    public static func all(_ db: SQLiteConnection) throws -> [LedgerCategory] {
        try db.query("SELECT \(columns) FROM categories ORDER BY type, sort_order, id", [], map)
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> LedgerCategory? {
        try db.queryOne("SELECT \(columns) FROM categories WHERE id = ?", [id], map)
    }

    public static func insert(_ db: SQLiteConnection, _ c: LedgerCategory, now: Date) throws {
        try db.run(
            "INSERT INTO categories (id, type, parent_id, name, symbol, sort_order, hidden, auto_key, locked, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [c.id, c.type.rawValue, c.parentID, c.name, c.symbol, c.sortOrder, c.hidden, c.autoKey, c.locked, now]
        )
    }

    /// 同一层里排在最后的位置
    public static func nextSortOrder(_ db: SQLiteConnection, type: CategoryType, parentID: String?) throws -> Int {
        let sql = "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories WHERE type = ? AND " + (parentID == nil ? "parent_id IS NULL" : "parent_id = ?")
        let values: [SQLBindable] = parentID.map { [type.rawValue, $0] } ?? [type.rawValue]
        return Int(try db.scalarInt(sql, values))
    }

    @discardableResult
    public static func update(_ db: SQLiteConnection, id: String, name: String, symbol: String) throws -> Bool {
        try db.run("UPDATE categories SET name = ?, symbol = ? WHERE id = ?", [name, symbol, id]) > 0
    }

    public static func setHidden(_ db: SQLiteConnection, id: String, hidden: Bool) throws {
        try db.run("UPDATE categories SET hidden = ? WHERE id = ?", [hidden, id])
    }

    public static func setParent(_ db: SQLiteConnection, id: String, parentID: String?, sortOrder: Int) throws {
        try db.run("UPDATE categories SET parent_id = ?, sort_order = ? WHERE id = ?", [parentID, sortOrder, id])
    }

    public static func setSortOrder(_ db: SQLiteConnection, id: String, sortOrder: Int) throws {
        try db.run("UPDATE categories SET sort_order = ? WHERE id = ?", [sortOrder, id])
    }

    public static func setAutoKey(_ db: SQLiteConnection, id: String, autoKey: String?) throws {
        try db.run("UPDATE categories SET auto_key = ? WHERE id = ?", [autoKey, id])
    }

    public static func delete(_ db: SQLiteConnection, id: String) throws {
        try db.run("DELETE FROM categories WHERE id = ?", [id])
    }
}

/// 学到的分类：同一个商户选过哪些分类。`merchant` 是「类型|归一化的商户」（见 `CategoryLearner`）。
public enum MerchantCategoryDAO {
    public struct Pick: Hashable, Sendable {
        public var categoryID: String
        public var picks: Int
        public var streak: Int
    }

    /// 学到的一条：某个商户选过某个分类
    public struct Entry: Hashable, Sendable {
        /// 「类型|归一化的商户」
        public var merchant: String
        public var categoryID: String
        public var picks: Int
        public var streak: Int
        public var lastPickedAt: Date
    }

    /// 学到的全部，按商户、最近选的在前（导出用）
    public static func all(_ db: SQLiteConnection) throws -> [Entry] {
        try db.query(
            "SELECT merchant, category_id, picks, streak, last_picked_at FROM merchant_categories ORDER BY merchant, streak DESC, last_picked_at DESC, category_id",
            []
        ) { Entry(merchant: $0.string(0), categoryID: $0.string(1), picks: Int($0.int(2)), streak: Int($0.int(3)), lastPickedAt: $0.date(4)) }
    }

    /// 这个商户选过的分类，最近选的在前
    public static func picks(_ db: SQLiteConnection, merchant: String) throws -> [Pick] {
        try db.query(
            """
            SELECT category_id, picks, streak FROM merchant_categories WHERE merchant = ?
            ORDER BY streak DESC, last_picked_at DESC, picks DESC, category_id
            """,
            [merchant]
        ) { Pick(categoryID: $0.string(0), picks: Int($0.int(1)), streak: Int($0.int(2))) }
    }

    /// 选了一次这个分类：它连续的次数 +1，这个商户别的分类重新数
    public static func addPick(_ db: SQLiteConnection, merchant: String, categoryID: String, at time: Date) throws {
        try db.run("UPDATE merchant_categories SET streak = 0 WHERE merchant = ? AND category_id <> ?", [merchant, categoryID])
        try db.run(
            """
            INSERT INTO merchant_categories (merchant, category_id, picks, streak, last_picked_at) VALUES (?, ?, 1, 1, ?)
            ON CONFLICT(merchant, category_id) DO UPDATE SET picks = picks + 1, streak = streak + 1, last_picked_at = excluded.last_picked_at
            """,
            [merchant, categoryID, time]
        )
    }

    /// 刚选的大类换成它下面的小类：两步算一次选择，退掉大类那一次，记到小类上
    public static func refine(_ db: SQLiteConnection, merchant: String, from parent: String, to child: String, at time: Date) throws {
        try db.run("UPDATE merchant_categories SET picks = picks - 1 WHERE merchant = ? AND category_id = ?", [merchant, parent])
        try db.run("DELETE FROM merchant_categories WHERE merchant = ? AND category_id = ? AND picks <= 0", [merchant, parent])
        try addPick(db, merchant: merchant, categoryID: child, at: time)
    }

    /// 这些分类并进 `target`。`keepStreak` 为 false 时不带连续次数，要重新学
    public static func move(_ db: SQLiteConnection, from ids: [String], to target: String, keepStreak: Bool) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            """
            INSERT INTO merchant_categories (merchant, category_id, picks, streak, last_picked_at)
            SELECT merchant, ?, picks, CASE WHEN ? THEN streak ELSE 0 END, last_picked_at FROM merchant_categories WHERE category_id IN (\(placeholders))
            ON CONFLICT(merchant, category_id) DO UPDATE SET
                picks = picks + excluded.picks, streak = MAX(streak, excluded.streak), last_picked_at = MAX(last_picked_at, excluded.last_picked_at)
            """,
            ([target, keepStreak] as [SQLBindable]) + ids.map { $0 as SQLBindable }
        )
        try remove(db, categoryIDs: ids)
    }

    public static func remove(_ db: SQLiteConnection, categoryIDs ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try db.run("DELETE FROM merchant_categories WHERE category_id IN (\(placeholders))", ids.map { $0 as SQLBindable })
    }
}

public enum SettingsDAO {
    public static func get(_ db: SQLiteConnection, _ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM settings WHERE key = ?", [key]) { $0.string(0) }
    }

    public static func set(_ db: SQLiteConnection, _ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }
}

/// WallClock 与数据库文本的互转：`YYYY-MM-DDTHH:MM[:SS]`，缺失部分用 `?` 占位。
public enum WallClockCodec {
    public static func encode(_ w: WallClock) -> String { w.sortKey }

    public static func decode(_ text: String, yearInferred: Bool) -> WallClock? {
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard let datePart = parts.first else { return nil }
        let dateFields = datePart.split(separator: "-").map(String.init)
        let year = dateFields.first.flatMap { Int($0) }
        let month = dateFields.count > 1 ? Int(dateFields[1]) : nil
        let day = dateFields.count > 2 ? Int(dateFields[2]) : nil
        var hour: Int?, minute: Int?, second: Int?
        if parts.count > 1 {
            let timeFields = parts[1].split(separator: ":").map { Int($0) }
            hour = timeFields.first ?? nil
            minute = timeFields.count > 1 ? timeFields[1] : nil
            second = timeFields.count > 2 ? timeFields[2] : nil
        }
        return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: second, yearInferred: yearInferred)
    }
}
