import Foundation
import BKModel
import BKDatabase

/// 导入方式（ADR 0019）：由用户选
public enum ImportMode: String, Sendable, CaseIterable {
    /// 增量：现在的数据一条不动，只加备份里有、这里没有的
    case merge
    /// 覆盖：现在的数据全部删掉，换成备份里的
    case replace
}

/// 备份里有什么：选了文件、还没导入时给用户看
public struct BackupInfo: Hashable, Sendable {
    public var records: Int
    public var accounts: Int
    /// 最晚一笔流水的时间：看得出是哪天的备份
    public var lastRecordAt: Date?

    public init(records: Int, accounts: Int, lastRecordAt: Date?) {
        self.records = records
        self.accounts = accounts
        self.lastRecordAt = lastRecordAt
    }
}

/// 导入的结果。增量时「已经有」的是这里本来就有、没有再加的
public struct ImportSummary: Hashable, Sendable {
    public var mode: ImportMode
    public var records = 0
    public var existingRecords = 0
    public var accounts = 0
    /// 增量时对上了这里已有的账户（同一个编号，或同一家银行、同一个尾号、同一种卡）
    public var existingAccounts = 0
    public var categories = 0

    public init(mode: ImportMode) {
        self.mode = mode
    }
}

/// 导入导出的数据库副本（`DataExport.backupName`），ADR 0019。整个导入在一个写事务里，出错整体回滚，现在的数据不变。
///
/// 备份先升级到这个版本的表结构（比 App 新的备份不能导入），之后两边的表一模一样，一行一行原样复制：
/// - **覆盖**：先清空每张表，再把备份里的全部放进来；
/// - **增量**：这里有的一条不动，备份里的逐条看「这里有没有」——
///   - 账户：同一个编号，或者同一家银行、同一个尾号、同一种卡（现金、电子钱包看名称）就是同一个，备份里这个账户的流水记到这里的那个上；
///   - 分类：同一个编号、同一个系统标识，或者同一类、同一个大类下同名的就是同一个；
///   - 通知：同一个编号或同一条内容（指纹）就是同一条；这里已经处理过的通知，它的待处理和余额不再加；
///   - 流水：同一个编号，或者换成这里的账户、通知编号之后去重键一样（同一条通知记出来的同一笔）就是同一笔；
///   - 初始余额、学到的分类、识别模板、某天的汇率、设置：这里已经有的不变。
///   配对的转帐、合成一单只剩一笔的（另一笔这里本来就有）不再算配对、合单。
/// - 卡面图片不在备份里：图片不在这台手机上的（`keepFaceImage` 为 false），清掉图片标识，卡面用颜色。
enum BackupImport {
    typealias Row = [String: SQLValue]

    /// 有外键的排在它引用的表后面：按这个顺序加，倒过来删
    static let tables = [
        "accounts", "opening_balances", "ingests", "records", "record_evidence", "balance_observations", "pending_items",
        "categories", "merchant_categories", "message_templates", "exchange_rate_days", "exchange_rates", "settings",
    ]

    /// 从导出的 zip 里取出数据库副本，写到临时文件，打开并升级表结构
    static func open(archive: Data, work: URL) throws -> SQLiteConnection {
        guard let entry = (try? ZipStore.entries(archive))?.first(where: { $0.name.hasSuffix(DataExport.backupName) }) else {
            throw BackendError.backupUnreadable
        }
        try entry.data.write(to: work, options: .atomic)
        return try open(database: work)
    }

    /// 打开一个数据库副本（导出的，或导入前自动存的）并升级到这个版本的表结构
    static func open(database url: URL) throws -> SQLiteConnection {
        let source: SQLiteConnection
        do {
            source = try SQLiteConnection(path: url.path)
            guard try source.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('accounts', 'records', 'ingests')") == 3 else {
                throw BackendError.backupUnreadable
            }
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.backupUnreadable
        }
        guard source.userVersion <= Migrations.latestVersion else { throw BackendError.backupTooNew }
        try Migrations.migrate(source)
        return source
    }

    static func info(_ source: SQLiteConnection) throws -> BackupInfo {
        BackupInfo(
            records: Int(try source.scalarInt("SELECT COUNT(*) FROM records")),
            accounts: Int(try source.scalarInt("SELECT COUNT(*) FROM accounts WHERE deleted_at IS NULL")),
            lastRecordAt: try source.queryOne("SELECT MAX(effective_at) FROM records", [], { $0.optionalDate(0) }) ?? nil
        )
    }

    static func run(_ db: SQLiteConnection, from source: SQLiteConnection, mode: ImportMode, keepFaceImage: (String) -> Bool) throws -> ImportSummary {
        switch mode {
        case .replace: try replace(db, from: source, keepFaceImage: keepFaceImage)
        case .merge: try merge(db, from: source, keepFaceImage: keepFaceImage)
        }
    }

    // MARK: 覆盖

    static func replace(_ db: SQLiteConnection, from source: SQLiteConnection, keepFaceImage: (String) -> Bool) throws -> ImportSummary {
        for table in tables.reversed() { try db.execute("DELETE FROM \(table)") }
        for table in tables {
            let columns = try columns(db, table)
            // 大类在小类前面（小类引用大类）
            for var row in try rows(source, table, order: table == "categories" ? "parent_id IS NOT NULL, rowid" : "rowid") {
                if table == "accounts" { clearMissingImage(&row, keepFaceImage) }
                try insert(db, table, row, columns: columns)
            }
        }
        var summary = ImportSummary(mode: .replace)
        summary.records = Int(try db.scalarInt("SELECT COUNT(*) FROM records"))
        summary.accounts = Int(try db.scalarInt("SELECT COUNT(*) FROM accounts"))
        summary.categories = Int(try db.scalarInt("SELECT COUNT(*) FROM categories"))
        return summary
    }

    // MARK: 增量

    static func merge(_ db: SQLiteConnection, from source: SQLiteConnection, keepFaceImage: (String) -> Bool) throws -> ImportSummary {
        var summary = ImportSummary(mode: .merge)

        var accountMap: [String: String] = [:]
        let localAccounts = try AccountDAO.all(db, includeArchived: true, includeDeleted: true)
        let accountColumns = try columns(db, "accounts")
        for var row in try rows(source, "accounts") {
            let id = row.text("id")
            if let same = localAccounts.first(where: { $0.id == id }) ?? localAccounts.first(where: { sameAccount($0, row) }) {
                accountMap[id] = same.id
                summary.existingAccounts += 1
                continue
            }
            clearMissingImage(&row, keepFaceImage)
            try insert(db, "accounts", row, columns: accountColumns)
            accountMap[id] = id
            summary.accounts += 1
        }
        try copy(source, "opening_balances", into: db) { row in
            row["account_id"] = remap(row["account_id"], accountMap)
            return true
        }

        var ingestMap: [String: String] = [:]
        /// 这里本来就有的通知（备份里的编号）
        var knownIngests: Set<String> = []
        let ingestColumns = try columns(db, "ingests")
        for var row in try rows(source, "ingests") {
            let id = row.text("id")
            if let existing = try db.queryOne("SELECT id FROM ingests WHERE id = ? OR fingerprint = ?", [id, row.text("fingerprint")], { $0.string(0) }) {
                ingestMap[id] = existing
                knownIngests.insert(id)
                continue
            }
            row["bound_account_id"] = remap(row["bound_account_id"], accountMap)
            try insert(db, "ingests", row, columns: ingestColumns)
            ingestMap[id] = id
        }

        var categoryMap: [String: String] = [:]
        var localCategories = try CategoryDAO.all(db)
        let categoryColumns = try columns(db, "categories")
        for var row in try rows(source, "categories", order: "parent_id IS NOT NULL, rowid") {
            let id = row.text("id")
            let parent = row.optionalText("parent_id").map { categoryMap[$0] ?? $0 }
            let autoKey = row.optionalText("auto_key")
            let same = localCategories.first { $0.id == id }
                ?? autoKey.flatMap { key in localCategories.first { $0.autoKey == key } }
                ?? localCategories.first { $0.type.rawValue == row.text("type") && $0.parentID == parent && $0.name == row.text("name") }
            if let same {
                categoryMap[id] = same.id
                continue
            }
            row["parent_id"] = parent.map(SQLValue.text) ?? .null
            try insert(db, "categories", row, columns: categoryColumns)
            categoryMap[id] = id
            localCategories = try CategoryDAO.all(db)
            summary.categories += 1
        }

        var recordMap: [String: String] = [:]
        let recordColumns = try columns(db, "records")
        for var row in try rows(source, "records", order: "effective_at, id") {
            let id = row.text("id")
            row["account_id"] = remap(row["account_id"], accountMap)
            row["ingest_id"] = remap(row["ingest_id"], ingestMap)
            row["category_id"] = remap(row["category_id"], categoryMap)
            row["merged_category_id"] = remap(row["merged_category_id"], categoryMap)
            let key = dedupeKey(row.text("dedupe_key"), accounts: accountMap, ingests: ingestMap)
            row["dedupe_key"] = .text(key)
            if let existing = try db.queryOne("SELECT id FROM records WHERE id = ? OR dedupe_key = ?", [id, key], { $0.string(0) }) {
                recordMap[id] = existing
                summary.existingRecords += 1
                continue
            }
            try insert(db, "records", row, columns: recordColumns)
            recordMap[id] = id
            summary.records += 1
        }
        // 退款对应的原单是这里本来就有的那笔：换成这里的编号
        for (old, new) in recordMap where old != new {
            try db.run("UPDATE records SET related_record_id = ? WHERE related_record_id = ?", [new, old])
        }
        try copy(source, "record_evidence", into: db) { row in
            row["record_id"] = remap(row["record_id"], recordMap)
            row["ingest_id"] = remap(row["ingest_id"], ingestMap)
            return true
        }
        try copy(source, "balance_observations", into: db) { row in
            guard !knownIngests.contains(row.text("ingest_id")) else { return false }
            row["account_id"] = remap(row["account_id"], accountMap)
            row["ingest_id"] = remap(row["ingest_id"], ingestMap)
            row["record_id"] = remap(row["record_id"], recordMap)
            return true
        }
        try copy(source, "pending_items", into: db) { row in
            guard !knownIngests.contains(row.text("ingest_id")) else { return false }
            row["ingest_id"] = remap(row["ingest_id"], ingestMap)
            row["duplicate_of_record_id"] = remap(row["duplicate_of_record_id"], recordMap)
            let candidates = row.text("candidate_account_ids").split(separator: ",").map { accountMap[String($0)] ?? String($0) }
            row["candidate_account_ids"] = .text(candidates.joined(separator: ","))
            return true
        }
        try copy(source, "merchant_categories", into: db) { row in
            row["category_id"] = remap(row["category_id"], categoryMap)
            return true
        }
        try copy(source, "message_templates", into: db) { _ in true }
        // 某天的汇率：这里没有这一天才加，同一天的不拼两份
        let localDays = Set(try RateDAO.days(db))
        try copy(source, "exchange_rate_days", into: db) { row in !localDays.contains(row.text("day")) }
        try copy(source, "exchange_rates", into: db) { row in !localDays.contains(row.text("day")) }
        try copy(source, "settings", into: db) { _ in true }

        // 配对、合单的另一笔这里本来就有（没有再加）时，剩下的一笔不再算配对（手动合成转帐的回到合成前）、合单
        try RecordDAO.dissolveLoneTransferGroups(db)
        try db.execute("""
        UPDATE records SET order_group = NULL WHERE order_group IN \
        (SELECT order_group FROM records WHERE order_group IS NOT NULL GROUP BY order_group HAVING COUNT(*) < 2);
        """)
        return summary
    }

    /// 同一张卡：同一家银行、同一个尾号、同一种卡；现金、电子钱包没有尾号，看名称。删除的不算
    static func sameAccount(_ local: Account, _ row: Row) -> Bool {
        guard !local.deleted, (row["deleted_at"] ?? .null) == .null, local.bankName == row.text("bank_name"), local.last4 == row.text("last4"),
              local.cardType.rawValue == row.text("card_type") else { return false }
        return local.isCard || local.name == row.text("name")
    }

    /// 去重键里带着账户或通知的编号（`IngestEngine.dedupeKey`）：换成这里对应的编号再比
    static func dedupeKey(_ key: String, accounts: [String: String], ingests: [String: String]) -> String {
        var parts = key.components(separatedBy: "|")
        guard parts.count > 1 else { return key }
        switch parts[0] {
        case "ref", "t": parts[1] = accounts[parts[1]] ?? parts[1]
        case "i": parts[1] = ingests[parts[1]] ?? parts[1]
        default: return key
        }
        return parts.joined(separator: "|")
    }

    // MARK: 整行复制

    static func rows(_ db: SQLiteConnection, _ table: String, order: String = "rowid") throws -> [Row] {
        try db.query("SELECT * FROM \(table) ORDER BY \(order)", []) { row in
            var result: Row = [:]
            for index in 0..<row.columnCount { result[row.columnName(index)] = row.value(index) }
            return result
        }
    }

    static func columns(_ db: SQLiteConnection, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))", []) { $0.string(1) }
    }

    /// `orIgnore`：主键、唯一约束冲突时跳过（增量时这里已经有的不变）
    static func insert(_ db: SQLiteConnection, _ table: String, _ row: Row, columns: [String], orIgnore: Bool = false) throws {
        let sql = "INSERT \(orIgnore ? "OR IGNORE " : "")INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
        try db.run(sql, columns.map { (row[$0] ?? .null) as SQLBindable })
    }

    /// 增量：备份里这张表的每一行先改编号（`adjust` 返回 false 的不要），已经有的跳过
    static func copy(_ source: SQLiteConnection, _ table: String, into db: SQLiteConnection, adjust: (inout Row) throws -> Bool) throws {
        let columns = try columns(db, table)
        for var row in try rows(source, table) {
            guard try adjust(&row) else { continue }
            try insert(db, table, row, columns: columns, orIgnore: true)
        }
    }

    static func remap(_ value: SQLValue?, _ map: [String: String]) -> SQLValue {
        guard case .text(let id) = value ?? .null else { return value ?? .null }
        return .text(map[id] ?? id)
    }

    static func clearMissingImage(_ row: inout Row, _ keep: (String) -> Bool) {
        if case .text(let id) = row["face_image_id"] ?? .null, !keep(id) { row["face_image_id"] = .null }
    }
}

private extension Dictionary where Key == String, Value == SQLValue {
    func text(_ column: String) -> String { optionalText(column) ?? "" }

    func optionalText(_ column: String) -> String? {
        if case .text(let value) = self[column] ?? .null { return value }
        return nil
    }
}
