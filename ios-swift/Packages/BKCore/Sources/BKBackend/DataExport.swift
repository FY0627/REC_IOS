import Foundation
import BKModel
import BKDatabase

/// 导出了什么：流水几笔、账户几个，写了哪些文件
public struct DataExportSummary: Hashable, Sendable {
    public var records: Int
    public var accounts: Int
    public var files: [String]

    public init(records: Int, accounts: Int, files: [String]) {
        self.records = records
        self.accounts = accounts
        self.files = files
    }
}

/// 导出全部数据：一个 zip（`ZipStore`），里面一个文件夹，放每种数据一个 CSV（Numbers、Excel 都能打开），
/// 和一份完整的数据库副本（`backupName`，「导入数据」读的就是它，见 `BackupImport`）。ADR 0019。
///
/// - 卡面图片不导出（太大）；数据库副本里还留着图片的标识，导入时图片不在这台手机上就清掉；
/// - CSV 开头带 BOM，Excel 才认得出是 UTF-8 的中文；换行用 CRLF；
/// - 金额按币种的小数位、不加千位分隔，表格里能直接加减；流水的金额流入为正、流出为负；
/// - 时间是手机所在时区的「年-月-日 时:分:秒」；
/// - 编号是 App 里的标识，几个文件之间靠它对上（流水的「原始通知」对「原始通知.csv」的编号）。
enum DataExport {
    /// zip 里的数据库副本
    static let backupName = "备份（导入用）.sqlite"

    /// 打成 zip：`folderName` 是 zip 里那个文件夹的名字。不放说明文件
    static func archive(_ db: SQLiteConnection, folderName: String, calendar: Calendar, now: Date) throws -> (data: Data, summary: DataExportSummary) {
        var entries: [ZipStore.Entry] = []
        let summary = try tables(db, calendar: calendar) { name, text in
            entries.append(ZipStore.Entry(name: "\(folderName)/\(name)", data: Data(text.utf8)))
        }
        entries.append(ZipStore.Entry(name: "\(folderName)/\(backupName)", data: try databaseCopy(db)))
        return (ZipStore.archive(entries, modified: now, calendar: calendar), summary)
    }

    /// 完整的数据库副本（`VACUUM INTO`：一致的快照，不用停下自动记账）。不能在事务里调用
    static func databaseCopy(_ db: SQLiteConnection) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-copy-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try saveCopy(db, to: url)
        return try Data(contentsOf: url)
    }

    static func saveCopy(_ db: SQLiteConnection, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.execute("VACUUM INTO '\(url.path.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// 每种数据一个 CSV，交给 `write` 写出去
    static func tables(_ db: SQLiteConnection, calendar: Calendar, write: (String, String) throws -> Void) throws -> DataExportSummary {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date: (Date?) -> String = { $0.map(time.string(from:)) ?? "" }

        let accounts = try AccountDAO.all(db, includeArchived: true, includeDeleted: true)
        let accountNames = Dictionary(accounts.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        let tree = CategoryTree(try CategoryDAO.all(db))
        let records = try LedgerBackend.decorate(try RecordDAO.allRows(db), db: db, calendar: calendar)

        let tables: [(name: String, header: [String], rows: [[String]])] = [
            ("流水.csv", recordHeader, try recordRows(records, evidence: RecordDAO.allEvidence(db), date: date)),
            ("账户.csv", accountHeader, try accountRows(accounts, status: AccountDAO.automationStatus(db), date: date)),
            ("余额.csv", balanceHeader, try balanceRows(accounts, db: db, calendar: calendar, date: date)),
            ("分类.csv", categoryHeader, categoryRows(tree)),
            ("学到的分类.csv", learnedHeader, try learnedRows(MerchantCategoryDAO.all(db), tree: tree, date: date)),
            ("识别模板.csv", templateHeader, try TemplateDAO.all(db).reversed().map { templateRow($0, date: date) }),
            ("汇率.csv", rateHeader, try rateRows(db, date: date)),
            ("待处理.csv", pendingHeader, try PendingDAO.all(db).map { pendingRow($0, accounts: accountNames, date: date) }),
            ("原始通知.csv", ingestHeader, try IngestDAO.all(db).map { ingestRow($0, date: date) }),
            ("通知里的余额.csv", observationHeader, try BalanceDAO.all(db).map { observationRow($0, accounts: accountNames, date: date) }),
        ]
        for table in tables { try write(table.name, document(table.header, table.rows)) }
        return DataExportSummary(records: records.count, accounts: accounts.count, files: tables.map(\.name))
    }

    // MARK: CSV

    static func document(_ header: [String], _ rows: [[String]]) -> String {
        "\u{FEFF}" + ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// 有逗号、引号、换行的整格用引号括起来，里面的引号写两遍
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func money(_ minor: Int64?, _ currency: CurrencyCode?) -> String {
        guard let minor, let currency else { return "" }
        return MoneyFormat.plain(minor, exponent: currency.minorUnitExponent, grouping: false)
    }

    // MARK: 流水

    static let recordHeader = [
        "编号", "时间", "类型", "分类", "小类", "金额", "币种", "账户", "转帐另一边", "交易对方", "备注", "交易性质", "状态", "来源", "自动归类",
        "扣款币种", "实际扣款", "通知里的交易时间", "通知里的余额", "已拆出的手续费", "银行参考号", "转给谁", "转帐配对", "退款对应的流水", "合成一单", "原始通知",
    ]

    static func recordRows(_ rows: [RecordRow], evidence: [String: [String]], date: (Date?) -> String) -> [[String]] {
        rows.map { row in
            let r = row.record
            // 小类写在「小类」一列，大类在「分类」一列；待分类两列都空
            let category = row.category
            let charged = row.isConverted ? row.chargedCurrency : nil
            let party: String
            if r.needsTransferConfirmation {
                party = "还没确认"
            } else {
                party = switch r.transferParty {
                case .own: "自己的账户"
                case .other: "别人"
                case nil: ""
                }
            }
            // 手动记的没有通知
            var ingests = r.source == .manual ? [] : [r.ingestID]
            for id in evidence[r.id] ?? [] where !ingests.contains(id) && r.source != .manual { ingests.append(id) }
            return [
                r.id,
                date(r.effectiveAt),
                r.entryType.displayName,
                category.map { $0.parentName ?? $0.name } ?? "",
                category.flatMap { $0.parentName == nil ? nil : $0.name } ?? "",
                money(r.direction == .inflow ? r.amountMinor : -r.amountMinor, r.currency),
                r.currency.rawValue,
                row.account.text,
                row.peer?.text ?? "",
                r.counterparty ?? "",
                r.note,
                r.kind.displayName,
                r.status.displayName,
                r.source.displayName,
                r.categoryAuto ? "是" : "",
                charged?.rawValue ?? "",
                money(r.settlementMinor, charged),
                r.transactionTime?.displayText ?? "",
                money(r.balanceAfterMinor, r.currency),
                money(r.includedFeeMinor, r.currency),
                r.bankReference ?? "",
                party,
                r.transferGroupID ?? "",
                r.relatedRecordID ?? "",
                r.orderGroupID ?? "",
                ingests.joined(separator: " "),
            ]
        }
    }

    // MARK: 账户和余额

    static let accountHeader = [
        "编号", "显示为", "名称", "银行", "尾号", "卡号", "账号", "类型", "主币种", "其他币种", "卡面颜色", "状态", "添加时间", "删除时间",
        "最近一次自动记账", "自动记账来源", "自动记账次数",
    ]

    static func accountRows(_ accounts: [Account], status: [AccountAutomationStatus], date: (Date?) -> String) -> [[String]] {
        let status = Dictionary(status.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.map { a in
            let automation = status[a.id]
            return [
                a.id, a.displayTitle, a.name, a.bankName, a.last4, a.cardNumber ?? "", a.accountNumber ?? "", a.cardType.displayName,
                a.currency.rawValue, a.extraCurrencies.map(\.rawValue).joined(separator: " "), a.paletteID,
                a.deleted ? "已删除" : a.archived ? "停用" : "使用中", date(a.createdAt), date(a.deletedAt),
                date(automation?.lastSuccessAt), automation?.lastSuccessSource?.displayName ?? "", automation.map { String($0.receivedCount) } ?? "",
            ]
        }
    }

    static let balanceHeader = ["账户编号", "账户", "币种", "初始余额", "初始余额时间", "推算余额", "冻结中", "可用余额", "没有汇率、没算进去的笔数"]

    /// 和卡包里一样：每个币种从初始余额出发，加上之后的已入账流水；没填初始余额的余额未知
    static func balanceRows(_ accounts: [Account], db: SQLiteConnection, calendar: Calendar, date: (Date?) -> String) throws -> [[String]] {
        let charges = ChargeCalculator(db: db, calendar: calendar)
        var rows: [[String]] = []
        for account in accounts {
            for item in try LedgerBackend.balanceSummaries(db, account: account, charges: charges) {
                rows.append([
                    account.id, account.displayTitle, item.currency.rawValue, money(item.openingBalanceMinor, item.currency), date(item.openingBalanceAt),
                    money(item.ledgerDerivedMinor, item.currency), money(item.openHoldsMinor, item.currency), money(item.availableMinor, item.currency),
                    String(item.unconvertedCount),
                ])
            }
        }
        return rows
    }

    // MARK: 分类

    static let categoryHeader = ["编号", "类型", "大类", "名称", "图标", "顺序", "隐藏", "系统标识", "不能删除"]

    /// 按分类页的顺序：大类后面跟着它的小类，隐藏的也在
    static func categoryRows(_ tree: CategoryTree) -> [[String]] {
        CategoryType.allCases.flatMap { type in
            tree.nodes(type, includeHidden: true).flatMap { node in
                ([node.category] + node.children).map { c in
                    [
                        c.id, c.type.displayName, c.isTopLevel ? "" : node.category.name, c.name, c.symbol, String(c.sortOrder),
                        c.hidden ? "是" : "", c.autoKey ?? "", c.locked ? "是" : "",
                    ]
                }
            }
        }
    }

    static let learnedHeader = ["类型", "商户", "分类", "选过几次", "连续几次", "最近一次"]

    /// 学到的分类（ADR 0017）：商户是认出来的键，`类型|商户`
    static func learnedRows(_ entries: [MerchantCategoryDAO.Entry], tree: CategoryTree, date: (Date?) -> String) -> [[String]] {
        entries.map { entry in
            let parts = entry.merchant.split(separator: "|", maxSplits: 1).map(String.init)
            let type = parts.first.flatMap(CategoryType.init(rawValue:))?.displayName ?? parts.first ?? ""
            return [
                type, parts.count > 1 ? parts[1] : entry.merchant, tree.label(entry.categoryID)?.fullName ?? entry.categoryID,
                String(entry.picks), String(entry.streak), date(entry.lastPickedAt),
            ]
        }
    }

    // MARK: 识别模板和汇率

    static let templateHeader = ["名称", "写法", "类型", "交易性质", "添加时间"]

    static func templateRow(_ t: MessageTemplate, date: (Date?) -> String) -> [String] {
        let entry = MessageTemplate.entry(kind: t.kind, direction: t.direction)
        return [t.name, t.preview, entry.type.displayName + (entry.refund ? "（退款）" : ""), t.kind.displayName, date(t.createdAt)]
    }

    static let rateHeader = ["日期", "基准币种", "币种", "1 个基准币种换多少", "数据源更新时间"]

    static func rateRows(_ db: SQLiteConnection, date: (Date?) -> String) throws -> [[String]] {
        try RateDAO.dayInfo(db).flatMap { day in
            try RateDAO.rates(db, day: day.day).sorted { $0.key < $1.key }.map { code, rate in
                [day.day, day.base, code, String(rate), date(day.updatedAt)]
            }
        }
    }

    // MARK: 待处理和原始通知

    static let pendingHeader = [
        "时间", "原因", "状态", "金额", "币种", "方向", "交易性质", "尾号", "交易对方", "通知里的交易时间", "候选账户", "可能重复的流水", "原始通知", "所在的句子",
    ]

    static func pendingRow(_ p: PendingItem, accounts: [String: String], date: (Date?) -> String) -> [String] {
        let d = p.draft
        let status = switch p.status {
        case .open: "待处理"
        case .confirmed: "已记入"
        case .ignored: "已忽略"
        }
        return [
            date(p.receivedAt ?? p.createdAt), p.reason.displayName, status, d?.amount.digits ?? "",
            d.map { $0.amount.preferredCurrency?.rawValue ?? $0.amount.currencyCandidates.map(\.rawValue).joined(separator: "/") } ?? "",
            d?.direction?.displayName ?? "", d?.kind.displayName ?? "", d?.cardTail ?? "", d?.counterparty ?? "", d?.transactionTime?.displayText ?? "",
            p.candidateAccountIDs.map { accounts[$0] ?? $0 }.joined(separator: " / "), p.duplicateOfRecordID ?? "", p.ingestID, d?.evidenceSnippet ?? "",
        ]
    }

    static let ingestHeader = ["编号", "来源", "发件人", "主题", "接收时间", "处理时间", "认成", "结果", "说明", "原文"]

    /// 原文过了保留天数会删掉，验证码不保存，这些「原文」一列是空的
    static func ingestRow(_ entry: IngestLogEntry, date: (Date?) -> String) -> [String] {
        let outcome = switch entry.outcome {
        case .recorded: "已入账"
        case .pending: "进了待处理"
        case .filtered: "不是交易"
        case .duplicateInput: "重复收到"
        case .mergedDuplicate: "和已有的流水是同一笔"
        }
        return [
            entry.id, entry.source.displayName, entry.sender ?? "", entry.subject ?? "", date(entry.receivedAt), date(entry.processedAt),
            entry.classification.displayName, outcome, entry.detail, entry.rawText ?? "",
        ]
    }

    static let observationHeader = ["账户", "币种", "余额", "通知里的时间", "收到的时间", "对应的流水"]

    static func observationRow(_ o: BalanceObservation, accounts: [String: String], date: (Date?) -> String) -> [String] {
        [
            accounts[o.accountID] ?? o.accountID, o.currency.rawValue, money(o.amountMinor, o.currency), o.transactionTime?.displayText ?? "",
            date(o.observedAt), o.recordID ?? "",
        ]
    }
}
