import Foundation
import BKModel
import BKDatabase

public enum BackendError: Error, Equatable, Sendable {
    case notFound
    case invalidAccount(AccountValidationError)
    /// 只有停用的账户才能删除
    case accountNotArchived
    /// 待处理项不允许确认（例如无法识别的通知），只能忽略
    case confirmationNotAllowed
    /// 选择的账户不在系统给出的候选里
    case accountNotACandidate
    case alreadyResolved
    /// 模板里没有圈出金额
    case invalidTemplate
    /// 流水金额必须大于 0
    case invalidAmount
    /// 分类名称为空、层级超过两层、类型对不上
    case invalidCategory
    /// 转帐和系统分类不能删除、合并
    case categoryLocked
    /// 导入的不是 REC 导出的 zip，或者被别的软件改过（重新压缩了）
    case backupUnreadable
    /// 备份来自更新版本的 App：先更新 App 再导入
    case backupTooNew
    /// 转帐缺少一边，或者转出、转入是同一个账户的同一个币种
    case invalidTransfer
    /// 合成一单至少要两笔，而且都是已入账的同一币种的支出（或收入）
    case invalidOrder
    /// 只有已入账的退款能关联到已入账的同一币种的支出（不是退款）
    case invalidRefund
}

/// App 界面与 App Intent 共用的业务入口。
///
/// 所有方法都是 async，并在数据库的串行队列上执行；调用方即使在 MainActor 上，
/// 解析、匹配、去重和 SQL 也不会占用主线程。
public final class LedgerBackend: Sendable {
    let database: Database
    let clock: @Sendable () -> Date
    let calendar: Calendar
    let newID: @Sendable () -> String

    public init(database: Database, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }, newID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.database = database
        self.calendar = calendar
        self.clock = clock
        self.newID = newID
    }

    public static func open(at url: URL, calendar: Calendar = .current) throws -> LedgerBackend {
        LedgerBackend(database: try Database(path: url.path), calendar: calendar)
    }

    public static func inMemory(calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) throws -> LedgerBackend {
        LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: clock)
    }

    private func engine(_ db: SQLiteConnection) -> IngestEngine {
        IngestEngine(db: db, now: clock(), calendar: calendar, newID: newID)
    }

    // MARK: 自动记账入口

    /// 处理一条短信 / 邮件。重复调用、并发调用都是幂等的。
    public func ingest(_ request: IngestRequest) async throws -> IngestResult {
        let now = clock()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            try IngestEngine(db: db, now: now, calendar: calendar, newID: newID).run(request)
        }
    }

    /// 付款页截图（ADR 0021）：App 在手机上识别出的文字行和位置，`capturedAt` 是截图的时间（没有就是现在）
    public func ingestScreenshot(lines: [ScreenTextLine], capturedAt: Date?) async throws -> IngestResult {
        try await ingestScreenshot(text: ScreenLayout.text(lines), capturedAt: capturedAt)
    }

    /// 付款页截图的文字：快捷指令「从图像中提取文本」交过来的也一样，一行一行
    public func ingestScreenshot(text: String, capturedAt: Date?) async throws -> IngestResult {
        try await ingest(IngestRequest(text: text, source: .screenshot, receivedAt: capturedAt ?? clock()))
    }

    // MARK: 账户

    /// 删除的账户只有 `includeDeleted` 时才有：它的流水还在，编辑流水、统计要找到它的名称
    public func accounts(includeArchived: Bool = false, includeDeleted: Bool = false) async throws -> [Account] {
        try await database.read { try AccountDAO.all($0, includeArchived: includeArchived, includeDeleted: includeDeleted) }
    }

    public func addAccount(_ draft: AccountDraft) async throws -> Account {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bankName = draft.bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bankName.isEmpty else { throw BackendError.invalidAccount(.emptyBank) }
        guard Account.isValidLast4(draft.last4) else { throw BackendError.invalidAccount(.invalidLast4) }
        let now = clock()
        let id = newID()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            let existing = try AccountDAO.all(db)
            if existing.contains(where: { $0.last4 == draft.last4 && $0.bankName == bankName && $0.cardType == draft.cardType }) {
                throw BackendError.invalidAccount(.duplicateAccount)
            }
            let extras = Account.normalizedExtras(draft.extraCurrencies, primary: draft.currency)
            // 没填余额的币种从 0 开始：添加之后到达的流水直接加减，余额不再显示「未知」
            var openings = [OpeningBalance(currency: draft.currency, amountMinor: draft.openingBalanceMinor ?? 0, at: now)]
            for currency in extras {
                openings.append(OpeningBalance(currency: currency, amountMinor: draft.extraOpeningBalances[currency] ?? 0, at: now))
            }
            let account = Account(
                id: id, name: name.isEmpty ? Account.defaultName(bankName: bankName, cardType: draft.cardType) : name, bankID: draft.bankID, bankName: bankName,
                last4: draft.last4, cardType: draft.cardType, currency: draft.currency, extraCurrencies: extras, paletteID: draft.paletteID,
                sortOrder: try AccountDAO.nextSortOrder(db), createdAt: now, openingBalances: openings
            )
            try AccountDAO.insert(db, account)
            // 账户添加之前收到的、因「没有匹配账户」而待处理的通知：现在能唯一匹配就入账
            try Self.rematchOpenPending(db, engine: IngestEngine(db: db, now: now, calendar: calendar, newID: newID))
            return account
        }
    }

    /// 卡面：配色、背景图标识、文字颜色和大小、金额的描边颜色和位置。只影响显示，不影响账户匹配。
    public func updateCardFace(accountID: String, paletteID: String, face: CardFace) async throws {
        var stored = face
        stored.textScale = min(CardFace.textScaleRange.upperBound, max(CardFace.textScaleRange.lowerBound, face.textScale))
        stored.amountX = CardFace.clampedAmountPosition(face.amountX)
        stored.amountY = CardFace.clampedAmountPosition(face.amountY)
        let face = stored
        let updated = try await database.write { try AccountDAO.updateFace($0, id: accountID, paletteID: paletteID, face: face) }
        if !updated { throw BackendError.notFound }
    }

    /// 卡片的新顺序（管理银行卡里拖动）
    public func reorderAccounts(_ ids: [String]) async throws {
        try await database.write { db in
            for (index, id) in ids.enumerated() { try AccountDAO.setSortOrder(db, id: id, sortOrder: index) }
        }
    }

    /// 卡片信息里可改的字段：账户名称（留空恢复默认名称）、选填的完整卡号（nil 或空串清除）、
    /// 多币种账户的其他币种（nil 表示不修改）。银行、尾号、卡类型、主币种决定自动记账的匹配，不在这里修改。
    public func updateCardInfo(accountID: String, name: String, cardNumber: String?, extraCurrencies: [CurrencyCode]? = nil) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNumber = cardNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var number: String?
        if !rawNumber.isEmpty {
            guard let normalized = Account.normalizedCardNumber(rawNumber) else { throw BackendError.invalidAccount(.invalidCardNumber) }
            number = normalized
        }
        let cardNumber = number
        try await database.write { db in
            guard let account = try AccountDAO.find(db, id: accountID) else { throw BackendError.notFound }
            if let cardNumber, !cardNumber.hasSuffix(account.last4) { throw BackendError.invalidAccount(.invalidCardNumber) }
            let name = trimmedName.isEmpty ? (account.isCard ? "\(account.bankName)\(account.cardType.displayName)" : account.bankName) : trimmedName
            try AccountDAO.updateInfo(db, id: accountID, name: name, cardNumber: cardNumber)
            if let extraCurrencies {
                let extras = Account.normalizedExtras(extraCurrencies, primary: account.currency)
                try AccountDAO.updateExtraCurrencies(db, id: accountID, primary: account.currency, extras: extras)
            }
        }
    }

    /// 卡片信息里修改账户：名称、卡类型、主币种、其他币种、完整卡号、账号、各币种的初始余额（银行和尾号不能改）。
    /// 改了主币种：已有流水保持原来的币种，之后没写币种的通知记为新的主币种；不再持有的币种，初始余额一起删除。
    public func updateAccount(id: String, _ edit: AccountEdit) async throws {
        let rawNumber = edit.cardNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var normalizedNumber: String?
        if !rawNumber.isEmpty {
            guard let value = Account.normalizedCardNumber(rawNumber) else { throw BackendError.invalidAccount(.invalidCardNumber) }
            normalizedNumber = value
        }
        let rawAccountNumber = edit.accountNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var normalizedAccountNumber: String?
        if !rawAccountNumber.isEmpty {
            guard let value = Account.normalizedAccountNumber(rawAccountNumber) else { throw BackendError.invalidAccount(.invalidAccountNumber) }
            normalizedAccountNumber = value
        }
        let cardNumber = normalizedNumber
        let accountNumber = normalizedAccountNumber
        let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = clock()
        try await database.write { db in
            guard let account = try AccountDAO.find(db, id: id) else { throw BackendError.notFound }
            if let cardNumber, !cardNumber.hasSuffix(account.last4) { throw BackendError.invalidAccount(.invalidCardNumber) }
            let others = try AccountDAO.all(db).filter { $0.id != id }
            if others.contains(where: { $0.last4 == account.last4 && $0.bankName == account.bankName && $0.cardType == edit.cardType }) {
                throw BackendError.invalidAccount(.duplicateAccount)
            }
            let extras = Account.normalizedExtras(edit.extraCurrencies, primary: edit.currency)
            // 现金、电子钱包没填名称：用添加时的名称
            let name = trimmedName.isEmpty
                ? (account.isCard ? Account.defaultName(bankName: account.bankName, cardType: edit.cardType) : account.bankName) : trimmedName
            try AccountDAO.updateDetails(
                db, id: id, name: name, cardType: edit.cardType, currency: edit.currency, extras: extras,
                cardNumber: cardNumber, accountNumber: accountNumber
            )
            let held = Set([edit.currency] + extras)
            for change in edit.openingBalanceChanges where held.contains(change.currency) {
                try AccountDAO.setOpeningBalance(db, id: id, currency: change.currency, amountMinor: change.amountMinor, at: now)
            }
        }
    }

    /// 设置或清除这张卡的账号（户口号码，可以是打码的形式）。传 nil 或空字符串清除。
    public func updateAccountNumber(accountID: String, accountNumber: String?) async throws {
        let raw = accountNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var normalized: String?
        if !raw.isEmpty {
            guard let value = Account.normalizedAccountNumber(raw) else { throw BackendError.invalidAccount(.invalidAccountNumber) }
            normalized = value
        }
        let value = normalized
        let updated = try await database.write { try AccountDAO.updateAccountNumber($0, id: accountID, accountNumber: value) }
        if !updated { throw BackendError.notFound }
    }

    /// 设置这张卡某个币种「现在」的余额（最小货币单位）；传 nil 清除。不指定币种时为主币种。
    /// 之后到达的同币种流水会加到这个数上；更早的流水和银行通知余额不受影响。
    public func setOpeningBalance(accountID: String, currency: CurrencyCode? = nil, amountMinor: Int64?) async throws {
        let now = clock()
        let updated = try await database.write { db -> Bool in
            guard let account = try AccountDAO.find(db, id: accountID) else { return false }
            return try AccountDAO.setOpeningBalance(db, id: accountID, currency: currency ?? account.currency, amountMinor: amountMinor, at: now)
        }
        if !updated { throw BackendError.notFound }
    }

    /// 隐藏账户（保留其历史流水）。
    public func setArchived(accountID: String, archived: Bool) async throws {
        try await database.write { try AccountDAO.setArchived($0, id: accountID, archived: archived) }
    }

    /// 删除停用的账户，不能恢复。它的流水留着（账户名称后面写「已删除」），不再出现在账户列表、净资产和自动记账里。
    /// 使用中的账户要先停用（`accountNotArchived`）
    public func deleteAccount(id: String) async throws {
        let now = clock()
        try await database.write { db in
            guard let account = try AccountDAO.find(db, id: id), !account.deleted else { throw BackendError.notFound }
            guard account.archived else { throw BackendError.accountNotArchived }
            try AccountDAO.markDeleted(db, id: id, at: now)
        }
    }

    public func automationStatus() async throws -> [String: AccountAutomationStatus] {
        try await database.read { db in
            Dictionary(uniqueKeysWithValues: try AccountDAO.automationStatus(db).map { ($0.accountID, $0) })
        }
    }

    // MARK: 流水

    public func records(accountID: String? = nil, before cursor: RecordCursor? = nil, limit: Int = 50) async throws -> [RecordRow] {
        try await records(filter: RecordFilter(accountID: accountID), before: cursor, limit: limit)
    }

    /// 按条件查流水（卡片详情按币种、时间段；首页搜索按关键字、支出 / 收入 / 转帐）。
    /// 账户不持有的币种的流水带上按主币种扣款的金额；转帐带上转帐分类；合成一单的带上同一单的几笔
    public func records(filter: RecordFilter, before cursor: RecordCursor? = nil, limit: Int = 50) async throws -> [RecordRow] {
        let calendar = calendar
        return try await database.read { db in
            try Self.decorate(try RecordDAO.page(db, filter: filter, before: cursor, limit: limit), db: db, calendar: calendar)
        }
    }

    /// 列表行补上：外币扣款、转帐分类（按交易性质对应）、同一单的几笔
    static func decorate(_ rows: [RecordRow], db: SQLiteConnection, calendar: Calendar) throws -> [RecordRow] {
        var rows = try withCharges(rows, db: db, calendar: calendar)
        if rows.contains(where: { $0.record.entryType == .transfer }) {
            let tree = CategoryTree(try CategoryDAO.all(db))
            for index in rows.indices where rows[index].record.entryType == .transfer {
                rows[index].category = tree.category(autoKey: CategoryKey.transfer(for: rows[index].record.kind))
                    .map { CategoryLabel(id: $0.id, name: $0.name, symbol: $0.symbol) }
            }
        }
        let groups = Set(rows.compactMap(\.record.orderGroupID))
        if !groups.isEmpty {
            let members = Dictionary(grouping: try RecordDAO.inOrderGroup(db, groups: Array(groups)), by: { $0.record.orderGroupID ?? "" })
            for index in rows.indices {
                guard let group = rows[index].record.orderGroupID, let parts = members[group], parts.count > 1 else { continue }
                rows[index].orderParts = parts.map {
                    OrderPart(recordID: $0.id, account: $0.account, amountMinor: $0.record.amountMinor, currency: $0.record.currency)
                }
            }
        }
        return rows
    }

    public func recordCount(accountID: String? = nil) async throws -> Int {
        try await recordCount(filter: RecordFilter(accountID: accountID))
    }

    public func recordCount(filter: RecordFilter) async throws -> Int {
        try await database.read { try RecordDAO.count($0, filter: filter) }
    }

    // MARK: 导出、导入（ADR 0019）

    /// 把全部数据导出成一个 zip（`DataExport`）写到 `url`；zip 里的文件夹和文件同名（去掉 .zip）。
    /// `extras`：账本以外的文件（卡面图片、设置，`BackupExtras`）。在数据库队列上生成和写文件，不占主线程
    public func exportData(to url: URL, extras: [String: Data] = [:]) async throws -> DataExportSummary {
        let calendar = calendar
        let now = clock()
        return try await database.read { db in
            let folder = url.deletingPathExtension().lastPathComponent
            let result = try DataExport.archive(db, folderName: folder, extras: extras, calendar: calendar, now: now)
            try result.data.write(to: url, options: .atomic)
            return result.summary
        }
    }

    /// 选了导出的 zip、还没导入：里面有什么
    public func backupInfo(archive: Data) async throws -> BackupInfo {
        try await database.read { _ in
            let work = Self.workFile()
            defer { try? FileManager.default.removeItem(at: work) }
            var info = try BackupImport.info(try BackupImport.open(archive: archive, work: work))
            let extras = try BackupExtras.files(in: archive)
            info.faceImages = BackupExtras.faceImages(extras).count
            info.hasSettings = extras[BackupExtras.settingsName] != nil
            return info
        }
    }

    /// 导入导出的 zip。`keepFaceImage`：卡面图片在这台手机上（不在就清掉图片标识）。整个导入是一个写事务，出错整体回滚
    public func importBackup(archive: Data, mode: ImportMode, keepFaceImage: @escaping @Sendable (String) -> Bool) async throws -> ImportSummary {
        try await database.write { db in
            let work = Self.workFile()
            defer { try? FileManager.default.removeItem(at: work) }
            return try BackupImport.run(db, from: try BackupImport.open(archive: archive, work: work), mode: mode, keepFaceImage: keepFaceImage)
        }
    }

    /// 导入一个数据库副本（导入前自动存的那份：撤销导入）
    public func importDatabase(at url: URL, mode: ImportMode, keepFaceImage: @escaping @Sendable (String) -> Bool) async throws -> ImportSummary {
        try await database.write { db in
            try BackupImport.run(db, from: try BackupImport.open(database: url), mode: mode, keepFaceImage: keepFaceImage)
        }
    }

    /// 把现在的数据存一份完整的副本（导入前自动存，撤销用）
    public func saveDatabaseCopy(to url: URL) async throws {
        try await database.read { db in try DataExport.saveCopy(db, to: url) }
    }

    private static func workFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-import-\(UUID().uuidString).sqlite")
    }

    static func withCharges(_ rows: [RecordRow], db: SQLiteConnection, calendar: Calendar) throws -> [RecordRow] {
        guard rows.contains(where: \.isConverted) else { return rows }
        let calculator = ChargeCalculator(db: db, calendar: calendar)
        return try rows.map { row in
            guard row.isConverted, let charged = row.chargedCurrency else { return row }
            var row = row
            row.charge = try calculator.charge(row.record, to: charged)
            return row
        }
    }

    /// 修改一笔流水。改了时间：交易时间和接收时间都改成它（影响排序和余额推算）；没改时间则保持原样。
    /// 配对的内部转账：另一边是手动补记的就跟着改（金额、币种、时间），仍是一对；填了到账多少（`edit.peerAmountMinor`）就用填的。
    /// 另一边是银行通知记的、或者是手动合成转帐的（用户自己记的那一笔）：填了到账多少时改它的金额和币种，仍是一对；
    /// 没填时改了账户、金额、币种、方向，或不再是转账类，就不再配对。
    /// 转帐可以换另一边的账户（`edit.peer`）。改了分类：同一单的几笔一起改，这笔不再算自动归类，这个商户重新学。转帐不保存分类
    public func updateRecord(id: String, _ edit: RecordEdit) async throws {
        guard edit.amountMinor > 0, (edit.peerAmountMinor ?? 1) > 0 else { throw BackendError.invalidAmount }
        let calendar = calendar
        let now = clock()
        let newID = newID
        try await database.write { db in
            guard var record = try RecordDAO.find(db, id: id) else { throw BackendError.notFound }
            guard let account = try AccountDAO.find(db, id: edit.accountID) else { throw BackendError.notFound }
            let original = record
            record.accountID = account.id
            record.amountMinor = edit.amountMinor
            record.currency = edit.currency
            record.direction = edit.direction
            record.kind = edit.kind
            let counterparty = edit.counterparty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            record.counterparty = counterparty.isEmpty ? nil : String(counterparty.prefix(200))
            record.note = String(edit.note.prefix(500))
            if let time = edit.time {
                let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
                record.transactionTime = WallClock(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
                record.receivedAt = time
            }
            // 从账户的哪个币种扣、实际扣了多少（账户没有这个币种，或者换了别的币种扣）
            record.setCharge(edit.chargeCurrency, actualMinor: edit.settlementMinor, account: account)
            if let party = edit.transferParty { record.transferParty = party }
            if record.kind != .transferIn, record.kind != .transferOut { record.transferParty = nil }
            if let group = original.transferGroupID {
                let peer = try RecordDAO.inGroup(db, group: group).first { $0.id != id }
                // 手动补记的另一边跟着这一笔改。手动合成转帐的另一边是用户自己记的支出（收入），和银行通知记的一样不跟着改时间、方向
                var follows = false
                if let peer, peer.source == .manual { follows = try !RecordDAO.isMergedTransfer(db, id: peer.id) }
                let stillTransfer = record.kind.isTransferLike && record.transferParty != .other
                let toItself = peer?.accountID == record.accountID && (edit.peerCurrency ?? peer?.currency) == record.currency
                let confirmedPeer = edit.peer == .keep && edit.peerAmountMinor != nil
                    && original.accountID == record.accountID && original.direction == record.direction
                if let peer, stillTransfer, !toItself, follows || confirmedPeer {
                    // 两边原来一样多时，没填到账多少就跟着这一笔；原来不一样（手续费、换汇）时不动
                    let matched = peer.amountMinor == original.amountMinor && peer.currency == original.currency
                    var synced = peer
                    synced.amountMinor = edit.peerAmountMinor ?? (matched ? record.amountMinor : peer.amountMinor)
                    synced.currency = edit.peerCurrency ?? (matched ? record.currency : peer.currency)
                    if synced.amountMinor != peer.amountMinor || synced.currency != peer.currency {
                        synced.chargeCurrency = nil
                        synced.settlementMinor = nil
                    }
                    if follows {
                        synced.direction = record.direction.opposite
                        synced.transactionTime = record.transactionTime
                        synced.receivedAt = record.receivedAt
                    }
                    _ = try RecordDAO.update(db, synced)
                } else if !stillTransfer || original.accountID != record.accountID || original.amountMinor != record.amountMinor
                            || original.currency != record.currency || original.direction != record.direction {
                    // 不再是一对：手动补记的另一边没有意义了，删掉；银行通知记的留着，手动合成转帐的另一边回到合成前的样子
                    if let peer, follows { _ = try RecordDAO.delete(db, id: peer.id) }
                    try RecordDAO.dissolveTransferGroup(db, group: group)
                    record.transferGroupID = nil
                }
            }
            if record.entryType == .transfer, edit.peer != .keep {
                try Self.changePeer(
                    edit.peer, of: &record, amountMinor: edit.peerAmountMinor ?? record.amountMinor, currency: edit.peerCurrency ?? record.currency,
                    account: account, db: db, now: now, newID: newID
                )
            }
            if !edit.keepsCategory { record.categoryID = edit.categoryID }
            let tree = CategoryTree(try CategoryDAO.all(db))
            if record.entryType == .transfer {
                record.categoryID = nil
            } else if let category = tree.category(record.categoryID), category.type != CategoryType(record.entryType) {
                // 支出改成了收入（或反过来）：原来的分类对不上了
                record.categoryID = nil
            }
            let categoryChanged = record.categoryID != original.categoryID
            if categoryChanged { record.categoryAuto = false }
            try RecordDAO.update(db, record)
            if categoryChanged, let categoryID = record.categoryID {
                if let group = record.orderGroupID {
                    try RecordDAO.setCategory(db, ids: try RecordDAO.inOrderGroup(db, groups: [group]).map(\.id), categoryID: categoryID)
                }
                try CategoryLearner(db: db).learn(record, categoryID: categoryID, replacing: original.categoryID, at: now)
            }
        }
    }

    /// 编辑转帐时换了另一边的账户。先拆开现在的另一边（手动补记的删掉，银行通知记的留着、不再配对，手动合成转帐的回到合成前），
    /// 再和新账户配对：那个账户前后 3 天里有对得上（`amountMinor`、`currency` 是另一边的金额和币种）、还没配对的一笔（银行通知记的）就配成一对，
    /// 没有就在那边补记一笔。可以是同一个账户的另一个币种（换汇）。
    /// 转进信用卡算还款。`untracked`：对方是自己没添加到 App 的账户，不配对
    static func changePeer(
        _ change: TransferPeerChange, of record: inout LedgerRecord, amountMinor: Int64, currency: CurrencyCode,
        account: Account, db: SQLiteConnection, now: Date, newID: () -> String
    ) throws {
        let recordID = record.id
        let current = try record.transferGroupID.map { group in try RecordDAO.inGroup(db, group: group).filter { $0.id != recordID } } ?? []
        if case .account(let peerID) = change, current.count == 1, current[0].accountID == peerID { return }
        for peer in current where peer.source == .manual {
            if try !RecordDAO.isMergedTransfer(db, id: peer.id) { _ = try RecordDAO.delete(db, id: peer.id) }
        }
        if let group = record.transferGroupID { try RecordDAO.dissolveTransferGroup(db, group: group) }
        record.transferGroupID = nil
        guard case .account(let peerID) = change else {
            if record.kind == .transferIn || record.kind == .transferOut { record.transferParty = .own }
            return
        }
        guard peerID != record.accountID || currency != record.currency, let target = try AccountDAO.find(db, id: peerID) else {
            throw BackendError.invalidTransfer
        }
        let repayment = peerID != record.accountID
            && ((record.direction == .outflow && target.cardType == .credit) || (record.direction == .inflow && account.cardType == .credit))
        if repayment {
            record.kind = .repayment
            record.transferParty = nil
        } else if record.kind == .repayment {
            record.kind = record.direction == .outflow ? .transferOut : .transferIn
        }
        if record.kind == .transferIn || record.kind == .transferOut { record.transferParty = .own }
        let group = newID()
        let at = record.effectiveAt
        let window: TimeInterval = 3 * 86_400
        let existing = try RecordDAO.candidates(
            db, amountMinor: amountMinor, currency: currency, direction: record.direction.opposite,
            effectiveFrom: at.addingTimeInterval(-window), effectiveTo: at.addingTimeInterval(window), excludingIngest: record.ingestID
        )
        .filter { $0.accountID == peerID && $0.id != recordID && $0.status == .posted && $0.kind.isTransferLike && $0.transferGroupID == nil }
        .min { abs($0.effectiveAt.timeIntervalSince(at)) < abs($1.effectiveAt.timeIntervalSince(at)) }
        if let existing {
            try RecordDAO.setTransferGroup(db, ids: [existing.id], group: group)
        } else {
            let ingestID = newID()
            try IngestDAO.insertManual(db, id: ingestID, receivedAt: at, processedAt: now)
            let peer = LedgerRecord(
                id: newID(), accountID: peerID, amountMinor: amountMinor, currency: currency, direction: record.direction.opposite,
                kind: repayment ? .repayment : (record.direction == .outflow ? .transferIn : .transferOut), status: .posted, counterparty: nil,
                transactionTime: record.transactionTime, receivedAt: at, processedAt: now, source: .manual, ingestID: ingestID, partIndex: 0,
                bankReference: nil, balanceAfterMinor: nil, includedFeeMinor: nil, note: "", transferGroupID: group, relatedRecordID: nil
            )
            _ = try RecordDAO.insertIfAbsent(db, peer, dedupeKey: "m|" + peer.id, now: now)
            try RecordDAO.addEvidence(db, recordID: peer.id, ingestID: ingestID, source: .manual, at: now)
        }
        record.transferGroupID = group
    }

    // MARK: 分类

    /// 全部分类（含隐藏的），按类型、顺序排好
    public func categories() async throws -> [LedgerCategory] {
        try await database.read { try CategoryDAO.all($0) }
    }

    /// 给一笔选分类（待分类、记账结果通知的按钮），可以顺手写备注。
    /// 没确认对方的转账选了分类就是转给别人。同一单的几笔一起改。选了和原来不一样的分类时这个商户记一次（`CategoryLearner`）
    public func setCategory(recordID: String, categoryID: String, note: String? = nil) async throws {
        let now = clock()
        try await database.write { db in
            guard var record = try RecordDAO.find(db, id: recordID) else { throw BackendError.notFound }
            guard let category = try CategoryDAO.find(db, id: categoryID), category.type != .transfer else { throw BackendError.invalidCategory }
            if record.needsTransferConfirmation {
                try RecordDAO.setTransferParty(db, id: record.id, party: .other)
                record.transferParty = .other
            }
            guard category.type == CategoryType(record.entryType) else { throw BackendError.invalidCategory }
            var ids = [record.id]
            if let group = record.orderGroupID { ids = try RecordDAO.inOrderGroup(db, groups: [group]).map(\.id) }
            try RecordDAO.setCategory(db, ids: ids, categoryID: categoryID)
            if record.categoryID != categoryID { try CategoryLearner(db: db).learn(record, categoryID: categoryID, replacing: record.categoryID, at: now) }
            if let note { _ = try RecordDAO.updateNote(db, id: record.id, note: String(note.prefix(500))) }
        }
    }

    /// 这一笔的候选分类（待分类面板、记账结果通知的按钮）
    public func categorySuggestions(recordID: String) async throws -> CategorySuggestions {
        try await database.read { db in
            guard let record = try RecordDAO.find(db, id: recordID) else { throw BackendError.notFound }
            return try CategoryLearner(db: db).suggestions(for: record, tree: CategoryTree(try CategoryDAO.all(db)))
        }
    }

    /// 分类建议体检：已经选好分类的流水重新推荐一遍，看建议准不准（`CategoryCheckupReplay`）。只读，不改账本
    public func categoryCheckup() async throws -> CategoryCheckup {
        let now = clock()
        return try await database.read { db in try CategoryCheckupReplay.run(db, now: now) }
    }

    static let learningSeededKey = "category.learning_seeded"

    /// 把已有的手选记录按时间回放一遍，学习不从零开始。只做一次
    public func seedCategoryLearning() async throws {
        try await database.write { db in
            guard try SettingsDAO.get(db, Self.learningSeededKey) == nil else { return }
            let learner = CategoryLearner(db: db)
            for record in try RecordDAO.categorized(db) {
                if let categoryID = record.categoryID { try learner.learn(record, categoryID: categoryID, at: record.effectiveAt) }
            }
            try SettingsDAO.set(db, Self.learningSeededKey, "1")
        }
    }

    /// 待分类：已入账的支出、收入还没有分类（没确认对方的转账也在里面）
    public func uncategorized(limit: Int = 200) async throws -> [RecordRow] {
        let calendar = calendar
        return try await database.read { db in
            try Self.decorate(try RecordDAO.uncategorized(db, limit: limit), db: db, calendar: calendar)
        }
    }

    public func uncategorizedCount() async throws -> Int {
        try await database.read { try RecordDAO.uncategorizedCount($0) }
    }

    /// 新增分类：大类，或加在某个大类下面的小类（最多两层）。转帐的分类不能新增
    public func addCategory(_ draft: CategoryDraft) async throws -> LedgerCategory {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, draft.type != .transfer else { throw BackendError.invalidCategory }
        let id = newID()
        let now = clock()
        return try await database.write { db in
            if let parentID = draft.parentID {
                guard let parent = try CategoryDAO.find(db, id: parentID), parent.isTopLevel, parent.type == draft.type, !parent.locked else {
                    throw BackendError.invalidCategory
                }
            }
            let category = LedgerCategory(
                id: id, type: draft.type, parentID: draft.parentID, name: String(name.prefix(20)),
                symbol: draft.symbol.isEmpty ? "tag" : draft.symbol,
                sortOrder: try CategoryDAO.nextSortOrder(db, type: draft.type, parentID: draft.parentID)
            )
            try CategoryDAO.insert(db, category, now: now)
            return category
        }
    }

    /// 改名、换图标（转帐和系统分类也可以）
    public func updateCategory(id: String, name: String, symbol: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BackendError.invalidCategory }
        let updated = try await database.write { try CategoryDAO.update($0, id: id, name: String(trimmed.prefix(20)), symbol: symbol.isEmpty ? "tag" : symbol) }
        if !updated { throw BackendError.notFound }
    }

    /// 隐藏：记账时不出现，已有记录不变。转帐分类不能隐藏
    public func setCategoryHidden(id: String, hidden: Bool) async throws {
        try await database.write { db in
            guard let category = try CategoryDAO.find(db, id: id) else { throw BackendError.notFound }
            guard category.type != .transfer else { throw BackendError.categoryLocked }
            try CategoryDAO.setHidden(db, id: id, hidden: hidden)
        }
    }

    /// 同一层里的新顺序
    public func reorderCategories(_ ids: [String]) async throws {
        try await database.write { db in
            for (index, id) in ids.enumerated() { try CategoryDAO.setSortOrder(db, id: id, sortOrder: index) }
        }
    }

    /// 把小类挪到别的大类下面；`parentID` 为 nil 时变成大类。下面还有小类的大类不能挪进别的大类
    public func moveCategory(id: String, toParent parentID: String?) async throws {
        try await database.write { db in
            guard let category = try CategoryDAO.find(db, id: id), !category.locked else { throw BackendError.categoryLocked }
            let all = try CategoryDAO.all(db)
            if let parentID {
                guard parentID != id, let parent = all.first(where: { $0.id == parentID }), parent.isTopLevel, parent.type == category.type, !parent.locked,
                      !all.contains(where: { $0.parentID == id }) else { throw BackendError.invalidCategory }
            }
            try CategoryDAO.setParent(db, id: id, parentID: parentID, sortOrder: try CategoryDAO.nextSortOrder(db, type: category.type, parentID: parentID))
        }
    }

    /// 合并：`id` 的流水改记到 `targetID`，学到的也并过去，然后删掉 `id`。
    /// 合并的是大类：它的小类挪到目标大类下面（目标是小类时，小类的流水也并进目标）
    public func mergeCategory(id: String, into targetID: String) async throws {
        try await database.write { db in
            guard id != targetID, let source = try CategoryDAO.find(db, id: id), let target = try CategoryDAO.find(db, id: targetID) else {
                throw BackendError.notFound
            }
            guard !source.locked else { throw BackendError.categoryLocked }
            guard source.type == target.type, target.type != .transfer, target.parentID != id else { throw BackendError.invalidCategory }
            let children = try CategoryDAO.all(db).filter { $0.parentID == id }
            for child in children {
                if target.isTopLevel {
                    try CategoryDAO.setParent(db, id: child.id, parentID: target.id, sortOrder: try CategoryDAO.nextSortOrder(db, type: target.type, parentID: target.id))
                } else {
                    try RecordDAO.reassignCategory(db, from: [child.id], to: target.id)
                    try MerchantCategoryDAO.move(db, from: [child.id], to: target.id, keepStreak: true)
                    try CategoryDAO.delete(db, id: child.id)
                }
            }
            try RecordDAO.reassignCategory(db, from: [id], to: target.id)
            try MerchantCategoryDAO.move(db, from: [id], to: target.id, keepStreak: true)
            try CategoryDAO.delete(db, id: id)
            // 自动归类用的标识（例如「工资」）交给目标分类
            if let key = source.autoKey, target.autoKey == nil { try CategoryDAO.setAutoKey(db, id: target.id, autoKey: key) }
        }
    }

    /// 删除分类（连同它的小类）。原来记在上面的流水改记到 `moveRecordsTo`；nil 时回到待分类。记录不删。
    /// 学到的跟着流水走，但不再自动归类，要重新学；回到待分类时清掉
    public func deleteCategory(id: String, moveRecordsTo targetID: String?) async throws {
        try await database.write { db in
            guard let category = try CategoryDAO.find(db, id: id) else { throw BackendError.notFound }
            guard !category.locked else { throw BackendError.categoryLocked }
            let removed = [id] + (try CategoryDAO.all(db).filter { $0.parentID == id }.map(\.id))
            if let targetID {
                guard !removed.contains(targetID), let target = try CategoryDAO.find(db, id: targetID), target.type == category.type else {
                    throw BackendError.invalidCategory
                }
            }
            try RecordDAO.reassignCategory(db, from: removed, to: targetID)
            if let targetID {
                try MerchantCategoryDAO.move(db, from: removed, to: targetID, keepStreak: false)
            } else {
                try MerchantCategoryDAO.remove(db, categoryIDs: removed)
            }
            for child in removed.dropFirst() { try CategoryDAO.delete(db, id: child) }
            try CategoryDAO.delete(db, id: id)
        }
    }

    // MARK: 手动记一笔

    static let lastManualAccountKey = "manual.last_account"

    /// 上次手动记账用的账户（还在使用中才返回）
    public func lastManualAccountID() async throws -> String? {
        try await database.read { db in
            guard let id = try SettingsDAO.get(db, Self.lastManualAccountKey), let account = try AccountDAO.find(db, id: id), !account.archived else { return nil }
            return id
        }
    }

    /// 手动记一笔。支出、收入记一条；转帐记两条（转出、转入）并配成一对，转入信用卡算还款。
    /// 转入那条用到账的金额和币种，差额（手续费、汇损）只体现在余额上，不算支出；同一个账户只能在两个币种之间转（换汇）。返回新流水的标识
    @discardableResult
    public func addRecord(_ entry: ManualEntry) async throws -> [String] {
        guard entry.amountMinor > 0, (entry.toAmountMinor ?? 1) > 0 else { throw BackendError.invalidAmount }
        let now = clock()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            guard let account = try AccountDAO.find(db, id: entry.accountID) else { throw BackendError.notFound }
            let ingestID = newID()
            try IngestDAO.insertManual(db, id: ingestID, receivedAt: entry.time, processedAt: now)
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: entry.time)
            let time = WallClock(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
            let counterparty = entry.counterparty
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            // 从账户的哪个币种扣款（入账）：选了就用选的，没选、账户又没有这个币种时按主币种。填了实际金额就存下来，否则按汇率估算
            func record(
                _ account: Account, _ direction: FlowDirection, _ kind: TransactionKind, part: Int, category: String?,
                charge: CurrencyCode?, settlement: Int64?, amount: Int64? = nil, currency: CurrencyCode? = nil
            ) -> LedgerRecord {
                var record = LedgerRecord(
                    id: newID(), accountID: account.id, amountMinor: amount ?? entry.amountMinor, currency: currency ?? entry.currency,
                    direction: direction, kind: kind, status: .posted, counterparty: counterparty,
                    transactionTime: time, receivedAt: entry.time, processedAt: now, source: .manual, ingestID: ingestID, partIndex: part,
                    bankReference: nil, balanceAfterMinor: nil, includedFeeMinor: nil, note: String(entry.note.prefix(500)),
                    transferGroupID: nil, relatedRecordID: nil, categoryID: category
                )
                record.setCharge(charge, actualMinor: settlement, account: account)
                return record
            }
            let tree = CategoryTree(try CategoryDAO.all(db))
            var category: String?
            if entry.type != .transfer, let id = entry.categoryID {
                guard let found = tree.category(id), found.type == CategoryType(entry.type) else { throw BackendError.invalidCategory }
                category = found.id
            }
            var records: [LedgerRecord]
            switch entry.type {
            case .expense:
                records = [record(
                    account, entry.isRefund ? .inflow : .outflow, entry.isRefund ? .refund : .purchase, part: 0, category: category,
                    charge: entry.chargeCurrency, settlement: entry.settlementMinor
                )]
            case .income:
                records = [record(
                    account, .inflow, .income, part: 0, category: category, charge: entry.chargeCurrency, settlement: entry.settlementMinor
                )]
            case .transfer:
                guard let toID = entry.toAccountID, let target = try AccountDAO.find(db, id: toID),
                      toID != account.id || (entry.toCurrency ?? entry.currency) != entry.currency else {
                    throw BackendError.invalidTransfer
                }
                let repayment = target.cardType == .credit && toID != account.id
                records = [
                    record(
                        account, .outflow, repayment ? .repayment : .transferOut, part: 0, category: nil,
                        charge: entry.chargeCurrency, settlement: entry.settlementMinor
                    ),
                    record(
                        target, .inflow, repayment ? .repayment : .transferIn, part: 2, category: nil, charge: nil, settlement: nil,
                        amount: entry.toAmountMinor, currency: entry.toCurrency
                    ),
                ]
                let group = newID()
                for index in records.indices { records[index].transferGroupID = group }
            }
            for r in records {
                _ = try RecordDAO.insertIfAbsent(db, r, dedupeKey: "m|" + r.id, now: now)
                try RecordDAO.addEvidence(db, recordID: r.id, ingestID: ingestID, source: .manual, at: now)
            }
            if let category { try CategoryLearner(db: db).learn(records[0], categoryID: category, at: now) }
            try SettingsDAO.set(db, Self.lastManualAccountKey, account.id)
            return records.map(\.id)
        }
    }

    /// 账户没有这个币种时，按它的主币种 `primary` 大概扣（入）多少：用 `time` 当天的汇率，那天没有就用日期最近的一天。
    /// 手动记一笔时提示；还没有汇率时金额为 nil
    public func estimateCharge(amountMinor: Int64, currency: CurrencyCode, to primary: CurrencyCode, at time: Date) async throws -> RecordCharge {
        let calendar = calendar
        return try await database.read { db in
            try ChargeCalculator(db: db, calendar: calendar).estimate(amountMinor, currency, at: time, primary: primary)
        }
    }

    /// 手动记账前查一下：同一个账户、同样金额和方向，前后 3 小时内已经有记录（多半是自动记账已经记过了）
    public func similarRecords(to entry: ManualEntry) async throws -> [RecordRow] {
        guard entry.type != .transfer else { return [] }
        let direction: FlowDirection = entry.type == .income || entry.isRefund ? .inflow : .outflow
        let window: TimeInterval = 3 * 3600
        let calendar = calendar
        return try await database.read { db in
            let rows = try RecordDAO.postedRows(db, from: entry.time.addingTimeInterval(-window), to: entry.time.addingTimeInterval(window))
                .filter { $0.record.accountID == entry.accountID && $0.record.amountMinor == entry.amountMinor
                    && $0.record.currency == entry.currency && $0.record.direction == direction }
            return try Self.decorate(rows, db: db, calendar: calendar)
        }
    }

    // MARK: 一单用了几张卡

    /// 可以和这一笔合成一单的流水：前后一天内、已入账、同一币种的同类（支出或收入），离得近的在前
    public func orderCandidates(recordID: String) async throws -> [RecordRow] {
        let calendar = calendar
        return try await database.read { db in
            guard let row = try RecordDAO.findRow(db, id: recordID) else { throw BackendError.notFound }
            let r = row.record
            let day: TimeInterval = 86_400
            let rows = try RecordDAO.postedRows(db, from: r.effectiveAt.addingTimeInterval(-day), to: r.effectiveAt.addingTimeInterval(day), limit: 300)
                .filter { other in
                    other.id != r.id && other.record.entryType == r.entryType && r.entryType != .transfer && other.record.currency == r.currency
                        && (other.record.orderGroupID == nil || other.record.orderGroupID != r.orderGroupID)
                }
                .sorted { abs($0.record.effectiveAt.timeIntervalSince(r.effectiveAt)) < abs($1.record.effectiveAt.timeIntervalSince(r.effectiveAt)) }
            return try Self.decorate(Array(rows.prefix(30)), db: db, calendar: calendar)
        }
    }

    /// 很可能是同一单：别的卡、10 分钟以内（只是提示，用户确认了才合并）
    public static func likelySameOrder(_ a: LedgerRecord, _ b: LedgerRecord) -> Bool {
        a.accountID != b.accountID && abs(a.effectiveAt.timeIntervalSince(b.effectiveAt)) <= 10 * 60
    }

    /// 合成一单：这几笔（和它们原来所在的单）共用一个合单标识；分类统一成第一笔有的分类
    public func mergeOrder(recordIDs: [String]) async throws {
        let newID = newID
        try await database.write { db in
            var records: [LedgerRecord] = []
            for id in recordIDs {
                guard let record = try RecordDAO.find(db, id: id) else { throw BackendError.notFound }
                records.append(record)
            }
            let groups = Array(Set(records.compactMap(\.orderGroupID)))
            for member in try RecordDAO.inOrderGroup(db, groups: groups).map(\.record) where !records.contains(where: { $0.id == member.id }) {
                records.append(member)
            }
            guard records.count >= 2, let first = records.first, first.entryType != .transfer,
                  records.allSatisfy({ $0.status == .posted && $0.currency == first.currency && $0.entryType == first.entryType }) else {
                throw BackendError.invalidOrder
            }
            let group = groups.first ?? newID()
            try RecordDAO.setOrderGroup(db, ids: records.map(\.id), group: group)
            if let category = records.compactMap(\.categoryID).first {
                try RecordDAO.setCategory(db, ids: records.map(\.id), categoryID: category)
            }
        }
    }

    /// 把这几笔从合成的一单里拆出去，各自单独显示（分类保留）。其余的还是一单，只剩一笔时不再是合单
    public func splitOrder(recordIDs: [String]) async throws {
        try await database.write { db in
            var groups: Set<String> = []
            for id in recordIDs {
                guard let record = try RecordDAO.find(db, id: id) else { throw BackendError.notFound }
                if let group = record.orderGroupID { groups.insert(group) }
            }
            try RecordDAO.leaveOrderGroup(db, ids: recordIDs)
            for group in groups { try RecordDAO.clearOrderGroupIfAlone(db, group: group) }
        }
    }

    // MARK: 退款关联到原交易

    /// 手动关联退款的候选。这一笔是退款：之前半年里同一币种、金额不小于它的支出（原交易）；
    /// 这一笔是支出：之后半年里同一币种、金额不大于它、还没关联到别的交易的退款。
    /// 退款常常退回别的账户（例如用卡付的退到余额），所以不限账户；同一个账户的在前，再按交易对方一样的、时间离得近的排
    public func refundLinkCandidates(recordID: String) async throws -> [RecordRow] {
        let calendar = calendar
        return try await database.read { db in
            guard let row = try RecordDAO.findRow(db, id: recordID) else { throw BackendError.notFound }
            let r = row.record
            guard r.status == .posted, r.entryType == .expense else { return [] }
            let window: TimeInterval = 180 * 86_400
            let day: TimeInterval = 86_400
            // 前后多留一天：通知的时间和真正交易的时间可能差一点
            let rows = r.isRefund
                ? try RecordDAO.refundLinkRows(
                    db, refunds: false, currency: r.currency, amount: r.amountMinor,
                    from: r.effectiveAt.addingTimeInterval(-window), to: r.effectiveAt.addingTimeInterval(day), excluding: r.id
                )
                : try RecordDAO.refundLinkRows(
                    db, refunds: true, currency: r.currency, amount: r.amountMinor,
                    from: r.effectiveAt.addingTimeInterval(-day), to: r.effectiveAt.addingTimeInterval(window), excluding: r.id
                )
            func rank(_ other: RecordRow) -> (Int, Int, TimeInterval) {
                let sameParty = r.counterparty != nil && other.record.counterparty == r.counterparty
                return (other.record.accountID == r.accountID ? 0 : 1, sameParty ? 0 : 1, abs(other.record.effectiveAt.timeIntervalSince(r.effectiveAt)))
            }
            let sorted = rows.sorted { rank($0) < rank($1) }
            return try Self.decorate(Array(sorted.prefix(30)), db: db, calendar: calendar)
        }
    }

    /// 把退款关联到原交易：原交易下面写「已退」，退款跟着原交易的分类（统计时从同一个分类里减掉）。
    /// 两笔都留着，各自的金额、时间、账户不变。退款原来关联到别的交易的，改成关联到这一笔
    public func linkRefunds(_ refundIDs: [String], to originID: String) async throws {
        try await database.write { db in
            guard let origin = try RecordDAO.find(db, id: originID) else { throw BackendError.notFound }
            guard origin.status == .posted, origin.entryType == .expense, origin.direction == .outflow else { throw BackendError.invalidRefund }
            for id in refundIDs {
                guard let refund = try RecordDAO.find(db, id: id) else { throw BackendError.notFound }
                guard refund.status == .posted, refund.isRefund, refund.currency == origin.currency else { throw BackendError.invalidRefund }
                try RecordDAO.setRelated(db, id: id, relatedID: originID)
            }
            if let category = origin.categoryID, !refundIDs.isEmpty {
                try RecordDAO.setCategory(db, ids: refundIDs, categoryID: category)
            }
        }
    }

    /// 取消退款和原交易的关联：两笔都留着，退款的分类不变
    public func unlinkRefund(_ refundID: String) async throws {
        try await database.write { db in
            guard let refund = try RecordDAO.find(db, id: refundID) else { throw BackendError.notFound }
            guard refund.isRefund else { throw BackendError.invalidRefund }
            try RecordDAO.clearRelated(db, id: refundID)
        }
    }

    // MARK: 一笔支出和另一个账户的一笔收入合成转帐

    /// 可以和这一笔合成转帐的另一边：别的账户、方向相反的支出（不是退款）或收入，前后 3 天内，离得近的在前。
    /// 币种、金额可以和这一笔不一样（手续费、换汇）
    public func transferMergeCandidates(recordID: String) async throws -> [RecordRow] {
        let calendar = calendar
        return try await database.read { db in
            guard let row = try RecordDAO.findRow(db, id: recordID) else { throw BackendError.notFound }
            let r = row.record
            guard r.canMergeIntoTransfer else { return [] }
            let window: TimeInterval = 3 * 86_400
            let rows = try RecordDAO.postedRows(db, from: r.effectiveAt.addingTimeInterval(-window), to: r.effectiveAt.addingTimeInterval(window), limit: 1000)
                .filter { other in
                    other.record.accountID != r.accountID && other.record.direction == r.direction.opposite && other.record.canMergeIntoTransfer
                }
                .sorted { abs($0.record.effectiveAt.timeIntervalSince(r.effectiveAt)) < abs($1.record.effectiveAt.timeIntervalSince(r.effectiveAt)) }
            return try Self.decorate(Array(rows.prefix(30)), db: db, calendar: calendar)
        }
    }

    /// 一个账户的一笔流出（支出）和另一个账户的一笔流入（收入）合成一笔转帐，例如微信提现到银行卡：
    /// 两笔都留着，金额、币种、时间、来源不变，共用一个转帐组，和自动配对的内部转帐一样不算收支；转进信用卡算还款。
    /// 金额、币种可以不一样，差额（手续费、汇损）只体现在余额上。合成前的交易性质、对方和分类记下来，拆开（`splitTransfer`）时改回去
    public func mergeTransfer(recordID: String, with otherID: String) async throws {
        let newID = newID
        try await database.write { db in
            guard let a = try RecordDAO.find(db, id: recordID), let b = try RecordDAO.find(db, id: otherID) else { throw BackendError.notFound }
            let (out, into) = a.direction == .outflow ? (a, b) : (b, a)
            guard out.direction == .outflow, into.direction == .inflow, out.accountID != into.accountID,
                  out.canMergeIntoTransfer, into.canMergeIntoTransfer,
                  let target = try AccountDAO.find(db, id: into.accountID) else { throw BackendError.invalidTransfer }
            let repayment = target.cardType == .credit
            try RecordDAO.mergeIntoTransfer(
                db, outflowID: out.id, outKind: repayment ? .repayment : .transferOut,
                inflowID: into.id, inKind: repayment ? .repayment : .transferIn, group: newID()
            )
        }
    }

    /// 拆开手动合成的转帐：两笔都回到合成前的支出、收入和分类；合成以后改过的金额、时间、备注留着
    public func splitTransfer(recordID: String) async throws {
        try await database.write { db in
            guard let record = try RecordDAO.find(db, id: recordID) else { throw BackendError.notFound }
            guard let group = record.transferGroupID, try RecordDAO.isMergedTransfer(db, id: recordID) else { throw BackendError.invalidTransfer }
            try RecordDAO.dissolveTransferGroup(db, group: group)
        }
    }

    /// 删除一笔流水。收到它的那条通知仍记着，同一条通知再来不会重新记上
    public func deleteRecord(id: String) async throws {
        let deleted = try await database.write { try RecordDAO.delete($0, id: id) }
        if !deleted { throw BackendError.notFound }
    }

    public func recordDetail(id: String) async throws -> RecordDetail {
        let calendar = calendar
        return try await database.read { db in
            guard let found = try RecordDAO.findRow(db, id: id) else { throw BackendError.notFound }
            let row = try Self.decorate([found], db: db, calendar: calendar)[0]
            let evidence = try RecordDAO.evidence(db, recordID: id)
            var peer: RecordRow?
            if let group = row.record.transferGroupID {
                peer = try RecordDAO.inGroup(db, group: group).first { $0.id != id }.flatMap { try RecordDAO.findRow(db, id: $0.id) }
            }
            let related = try row.record.relatedRecordID.flatMap { try RecordDAO.findRow(db, id: $0) }
            let members = try row.record.orderGroupID.map { try RecordDAO.inOrderGroup(db, groups: [$0]).filter { $0.id != id } } ?? []
            return RecordDetail(
                row: row, evidence: evidence, transferPeer: peer, related: related,
                refunds: try RecordDAO.refunds(db, of: id), fee: try RecordDAO.splitFee(db, of: row.record),
                orderMembers: try Self.decorate(members, db: db, calendar: calendar),
                mergedTransfer: try row.record.transferGroupID != nil && RecordDAO.isMergedTransfer(db, id: id)
            )
        }
    }

    /// 只改备注（其他字段一起改用 `updateRecord`）。
    public func updateNote(recordID: String, note: String) async throws {
        let trimmed = String(note.prefix(500))
        let updated = try await database.write { try RecordDAO.updateNote($0, id: recordID, note: trimmed) }
        if !updated { throw BackendError.notFound }
    }

    // MARK: 待处理

    public func openPendingItems() async throws -> [PendingItem] {
        try await database.read { try PendingDAO.open($0) }
    }

    public func pendingCount() async throws -> Int {
        try await database.read { try PendingDAO.openCount($0) }
    }

    /// 没配对到自己另一张卡、也还没确认对方是谁的转账。已经照常入账（按转给别人统计），确认后改变统计方式。
    public func unconfirmedTransfers() async throws -> [RecordRow] {
        try await database.read { try RecordDAO.unconfirmedTransfers($0) }
    }

    public func unconfirmedTransferCount() async throws -> Int {
        try await database.read { try RecordDAO.unconfirmedTransferCount($0) }
    }

    /// 确认转账的对方：自己的账户（内部转账，不计入收支）或别人。传 nil 恢复为未确认。
    public func setTransferParty(recordID: String, party: TransferParty?) async throws {
        try await database.write { db in
            guard try RecordDAO.setTransferParty(db, id: recordID, party: party) else { throw BackendError.notFound }
            // 自己的账户之间是转帐，不用分类
            if party == .own { try RecordDAO.setCategory(db, ids: [recordID], categoryID: nil) }
        }
    }

    /// 确认系统给出的候选。不能借此修改金额、方向、时间等字段。
    public func confirmPending(id: String, accountID: String) async throws {
        let now = clock()
        let calendar = calendar
        let newID = newID
        try await database.write { db in
            guard let item = try PendingDAO.find(db, id: id) else { throw BackendError.notFound }
            guard item.status == .open else { throw BackendError.alreadyResolved }
            guard item.reason.allowsConfirmation, let draft = item.draft else { throw BackendError.confirmationNotAllowed }
            let accounts = try AccountDAO.all(db)
            guard let account = accounts.first(where: { $0.id == accountID }) else { throw BackendError.notFound }
            let allowed: Bool
            if !item.candidateAccountIDs.isEmpty {
                allowed = item.candidateAccountIDs.contains(accountID)
            } else if let tail = draft.cardTail, accounts.contains(where: { !$0.archived && $0.matches(tail: tail) }) {
                allowed = account.matches(tail: tail)
            } else {
                // 通知里没有尾号，或尾号对不上任何卡：由用户选择记入哪张卡
                allowed = !account.archived
            }
            guard allowed else { throw BackendError.accountNotACandidate }
            guard let meta = try IngestDAO.meta(db, id: item.ingestID) else { throw BackendError.notFound }
            let engine = IngestEngine(db: db, now: now, calendar: calendar, newID: newID)
            let outcome = try engine.commit(
                draft, meta: .init(ingestID: item.ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                boundAccountID: nil, accounts: accounts, forcedAccount: account, duplicateCheck: false,
                forcedDedupeKey: item.reason == .possibleDuplicate ? "c|" + item.id : nil
            )
            if case .pending = outcome { throw BackendError.confirmationNotAllowed }
            _ = try PendingDAO.resolve(db, id: id, status: .confirmed, at: now)
            if item.reason == .ambiguousAmount {
                // 用户选定了这个金额：同一条通知里的其他候选金额不再需要处理
                try PendingDAO.ignoreOtherAmounts(db, ingestID: item.ingestID, keepingPart: draft.partIndex, at: now)
            }
        }
    }

    public func ignorePending(id: String) async throws {
        let now = clock()
        try await database.write { db in
            guard let item = try PendingDAO.find(db, id: id) else { throw BackendError.notFound }
            guard try PendingDAO.resolve(db, id: id, status: .ignored, at: now) else { throw BackendError.alreadyResolved }
            // 用户确认是重复：把这条通知记为原流水的另一份来源证据
            if item.reason == .possibleDuplicate, let original = item.duplicateOfRecordID {
                try RecordDAO.addEvidence(db, recordID: original, ingestID: item.ingestID, source: item.source, at: now)
            }
        }
    }

    // MARK: 识别模板

    public func templates() async throws -> [MessageTemplate] {
        try await database.read { try TemplateDAO.all($0) }
    }

    /// 保存用户在本机做的模板（新的或改过的），并用它重新识别还没处理的待处理项。返回重新识别的通知条数。
    public func saveTemplate(_ template: MessageTemplate) async throws -> Int {
        guard template.pieces.contains(.amount) else { throw BackendError.invalidTemplate }
        let now = clock()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            try TemplateDAO.save(db, template)
            return try IngestEngine(db: db, now: now, calendar: calendar, newID: newID).reapply(template)
        }
    }

    public func deleteTemplate(id: String) async throws {
        let deleted = try await database.write { try TemplateDAO.delete($0, id: id) }
        if !deleted { throw BackendError.notFound }
    }

    /// 新添加了账户：因为「没有匹配账户」（认出了银行或钱包的是「没写尾号」）待处理的通知，现在能唯一匹配就入账
    static func rematchOpenPending(_ db: SQLiteConnection, engine: IngestEngine) throws {
        let accounts = try AccountDAO.all(db)
        for item in try PendingDAO.open(db) {
            // 截图记到的钱包还没添加（ADR 0021）：按截图重新找账户，找到一个就记
            if item.reason == .noWalletAccount, let draft = item.draft, let raw = item.rawText, let meta = try IngestDAO.meta(db, id: item.ingestID) {
                let reading = ScreenshotParser.parse(raw, referenceDate: meta.receivedAt ?? meta.processedAt, calendar: engine.calendar)
                let route = engine.screenshotRoute(draft, reading: reading, accounts: accounts)
                guard let account = route.account else { continue }
                let outcome = try engine.commit(
                    draft, meta: .init(ingestID: item.ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                    boundAccountID: nil, accounts: accounts, forcedAccount: account, duplicateCheck: true, assumedAccount: route.assumed
                )
                if case .pending = outcome { continue }
                _ = try PendingDAO.resolve(db, id: item.id, status: .confirmed, at: engine.now)
                continue
            }
            guard let draft = item.draft, item.reason == .noMatchingAccount || (item.reason == .missingCardTail && (draft.walletHint != nil || draft.bankHint != nil)),
                  let meta = try IngestDAO.meta(db, id: item.ingestID) else { continue }
            guard case .matched = AccountMatcher.match(
                tail: draft.cardTail, bankHint: draft.bankHint, walletHint: draft.walletHint, boundAccountID: nil, accounts: accounts
            ) else { continue }
            let outcome = try engine.commit(
                draft, meta: .init(ingestID: item.ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                boundAccountID: nil, accounts: accounts, forcedAccount: nil, duplicateCheck: true
            )
            switch outcome {
            case .recorded, .merged: _ = try PendingDAO.resolve(db, id: item.id, status: .confirmed, at: engine.now)
            case .pending: continue
            }
        }
    }

    public func ingestLog(limit: Int = 50) async throws -> [IngestLogEntry] {
        try await database.read { try IngestDAO.recent($0, limit: limit) }
    }

    // MARK: 余额

    /// 每张卡每个币种的余额，币种顺序与账户一致（主币种在前）。
    public func balanceSummaries() async throws -> [String: AccountBalances] {
        let calendar = calendar
        return try await database.read { db in
            let charges = ChargeCalculator(db: db, calendar: calendar)
            var result: [String: AccountBalances] = [:]
            for account in try AccountDAO.all(db, includeArchived: true) {
                result[account.id] = AccountBalances(accountID: account.id, items: try Self.balanceSummaries(db, account: account, charges: charges))
            }
            return result
        }
    }

    /// 推算余额：每个币种从用户填写的初始余额出发，加上之后到达的、从这个币种扣款（入账）的已入账流水。没有初始余额时余额未知，不用部分流水冒充。
    /// 换成这个币种扣的（账户没有的币种按主币种，余额不够时换主币种，见 `LedgerRecord.chargedCurrency(in:)`）按实际金额或汇率估算计入；
    /// 还没有任何汇率、估算不出的不计入。还在冻结中的流出不计入余额，另外合计（`openHoldsMinor`），算可用余额用。
    /// 银行通知里写的余额不使用：很多银行的通知不带余额，写法和含义也不统一。
    ///
    /// 初始余额是用户在手机上填写的时刻；流水按「通知到达手机的时间」和它比较
    /// （通知内时间是银行所在地的时间，和手机时区可能不同）。
    static func balanceSummaries(_ db: SQLiteConnection, account: Account, charges: ChargeCalculator) throws -> [AccountBalanceSummary] {
        let currencies = account.currencies
        let records = try RecordDAO.forBalance(db, accountID: account.id)
        return try currencies.map { currency in
            guard let opening = account.openingBalance(currency) else {
                return AccountBalanceSummary(accountID: account.id, currency: currency, ledgerDerivedMinor: nil, recordsAfterBase: 0)
            }
            var total = opening.amountMinor
            var count = 0
            var unconverted = 0
            var holds: Int64 = 0
            for record in records where record.chargedCurrency(in: currencies) == currency && (record.receivedAt ?? record.processedAt) > opening.at {
                let amount: Int64
                if record.currency == currency {
                    amount = record.amountMinor
                } else if let value = try charges.charge(record, to: currency).amountMinor {
                    amount = value
                } else {
                    if record.status == .posted { unconverted += 1 }
                    continue
                }
                if record.status == .posted {
                    total += record.direction == .inflow ? amount : -amount
                    count += 1
                } else {
                    holds += amount
                }
            }
            return AccountBalanceSummary(
                accountID: account.id, currency: currency, ledgerDerivedMinor: total, recordsAfterBase: count,
                openingBalanceMinor: opening.amountMinor, openingBalanceAt: opening.at, unconvertedCount: unconverted, openHoldsMinor: holds
            )
        }
    }

    // MARK: 汇率

    /// 保存快捷指令导入的完整汇率表，按数据源的更新日期一天一份（同一天保留最后下载的）。
    /// 外币交易按交易当天的汇率估算扣款；以前的日期都保留。
    @discardableResult
    public func saveExchangeRates(_ rates: ExchangeRates) async throws -> Bool {
        let day = RateDay.key(rates.updatedAt, calendar: calendar)
        return try await database.write { try RateDAO.save($0, day: day, rates: rates) }
    }

    /// 账本里最近一天的汇率表。本机还没导入过汇率（例如新装后导入了备份）时，界面用它换算
    public func latestExchangeRates() async throws -> ExchangeRates? {
        try await database.read { try RateDAO.latest($0) }
    }

    // MARK: 统计

    /// 一个月的统计。`convertTo`：再把所有币种换算成这个币种合计（首页的本月支出、收入、结余）
    public func monthStats(year: Int, month: Int, convertTo primary: CurrencyCode? = nil) async throws -> MonthStats {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { throw BackendError.notFound }
        return try await stats(from: start, to: end, year: year, month: month, convertTo: primary)
    }

    /// 一段时间的统计（统计页按选的时间段看）：含 `from`，不含 `to`；nil 表示不限。`accountID`：只算这个账户。
    /// 结果里的年、月是开始那天所在的月（不限时为 0），只作标识
    public func stats(from: Date?, to: Date?, convertTo primary: CurrencyCode? = nil, accountID: String? = nil) async throws -> MonthStats {
        let c = from.map { calendar.dateComponents([.year, .month], from: $0) }
        return try await stats(
            from: from ?? .distantPast, to: to ?? .distantFuture, year: c?.year ?? 0, month: c?.month ?? 0, convertTo: primary, accountID: accountID
        )
    }

    private func stats(from start: Date, to end: Date, year: Int, month: Int, convertTo primary: CurrencyCode?, accountID: String? = nil) async throws -> MonthStats {
        let calendar = calendar
        return try await database.read { db in
            var records = try RecordDAO.inRange(db, from: start, to: end)
            if let accountID { records = records.filter { $0.accountID == accountID } }
            let categories = try CategoryDAO.all(db)
            var stats = StatsCalculator.month(year: year, month: month, records: records, categories: categories)
            if let primary {
                stats.converted = try StatsCalculator.converted(
                    records, to: primary, charges: ChargeCalculator(db: db, calendar: calendar), categories: categories
                )
            }
            return stats
        }
    }

    // MARK: 设置与清理

    public func rawRetentionDays() async throws -> Int {
        try await database.read { try SettingsDAO.get($0, IngestEngine.retentionKey).flatMap(Int.init) ?? IngestEngine.defaultRetentionDays }
    }

    public func setRawRetentionDays(_ days: Int) async throws {
        let clamped = min(365, max(1, days))
        try await database.write { try SettingsDAO.set($0, IngestEngine.retentionKey, String(clamped)) }
    }

    /// 清空到期的原始正文。待处理中的正文保留到处理完成。
    @discardableResult
    public func purgeExpiredRawContent() async throws -> Int {
        let now = clock()
        return try await database.write { try IngestDAO.purgeRaw($0, now: now) }
    }
}

enum StatsCalculator {
    /// 一个币种里，每个分类（nil 为待分类）的金额和笔数；退款是负数
    typealias CategorySums = [String?: (amount: Int64, count: Int)]

    static func month(year: Int, month: Int, records: [LedgerRecord], categories: [LedgerCategory] = []) -> MonthStats {
        var byCurrency: [CurrencyCode: MonthStats.CurrencyTotals] = [:]
        var byKind: [CurrencyCode: [String: MonthStats.KindTotal]] = [:]
        var byAccount: [String: MonthStats.AccountTotal] = [:]
        var expenseSums: [CurrencyCode: CategorySums] = [:]
        var incomeSums: [CurrencyCode: CategorySums] = [:]
        var holds = 0, failed = 0
        for r in records {
            switch r.status {
            case .hold, .holdReleased: holds += 1; continue
            case .failed: failed += 1; continue
            case .posted: break
            }
            var totals = byCurrency[r.currency] ?? .init(currency: r.currency, expenseMinor: 0, incomeMinor: 0, refundMinor: 0, internalTransferMinor: 0, repaymentMinor: 0, recordCount: 0, byKind: [])
            totals.recordCount += 1
            switch r.entryType {
            case .transfer:
                if r.isInternalTransfer {
                    if r.direction == .outflow { totals.internalTransferMinor += r.amountMinor }
                } else if r.kind == .repayment {
                    totals.repaymentMinor += r.amountMinor
                }
                // 配对的两边只算转出那边
                if r.direction == .outflow || r.transferGroupID == nil { totals.transferMinor += r.amountMinor }
            case .expense:
                let signed = r.isRefund ? -r.amountMinor : r.amountMinor
                if r.isRefund { totals.refundMinor += r.amountMinor } else { totals.expenseMinor += r.amountMinor }
                let sum = expenseSums[r.currency, default: [:]][r.categoryID] ?? (0, 0)
                expenseSums[r.currency, default: [:]][r.categoryID] = (sum.amount + signed, sum.count + 1)
            case .income:
                totals.incomeMinor += r.amountMinor
                let sum = incomeSums[r.currency, default: [:]][r.categoryID] ?? (0, 0)
                incomeSums[r.currency, default: [:]][r.categoryID] = (sum.amount + r.amountMinor, sum.count + 1)
            }
            byCurrency[r.currency] = totals

            let kindKey = r.kind.rawValue + "|" + r.direction.rawValue
            var kindTotal = byKind[r.currency]?[kindKey] ?? .init(kind: r.kind, direction: r.direction, amountMinor: 0, count: 0)
            kindTotal.amountMinor += r.amountMinor
            kindTotal.count += 1
            byKind[r.currency, default: [:]][kindKey] = kindTotal

            let accountKey = r.accountID + "|" + r.currency.rawValue
            var accountTotal = byAccount[accountKey] ?? .init(accountID: r.accountID, currency: r.currency, inflowMinor: 0, outflowMinor: 0, count: 0)
            if r.direction == .inflow { accountTotal.inflowMinor += r.amountMinor } else { accountTotal.outflowMinor += r.amountMinor }
            accountTotal.count += 1
            byAccount[accountKey] = accountTotal
        }
        let tree = CategoryTree(categories)
        let currencies = byCurrency.values.map { totals -> MonthStats.CurrencyTotals in
            var t = totals
            t.byKind = (byKind[t.currency] ?? [:]).values.sorted { $0.amountMinor > $1.amountMinor }
            t.expenseCategories = categoryTotals(expenseSums[t.currency] ?? [:], tree: tree)
            t.incomeCategories = categoryTotals(incomeSums[t.currency] ?? [:], tree: tree)
            return t
        }.sorted { $0.recordCount > $1.recordCount }
        return MonthStats(year: year, month: month, currencies: currencies, accounts: byAccount.values.sorted { $0.outflowMinor + $0.inflowMinor > $1.outflowMinor + $1.inflowMinor }, holdCount: holds, failedCount: failed)
    }

    /// 所有币种换算成 `primary` 的本月支出（减去退款）和收入，和按分类的合计。转帐不算。
    /// 外币交易填了实际扣款（正好是 `primary`）就用它，否则按交易当天的汇率；没有汇率的不计入
    static func converted(
        _ records: [LedgerRecord], to primary: CurrencyCode, charges: ChargeCalculator, categories: [LedgerCategory] = []
    ) throws -> MonthStats.ConvertedTotals {
        var expense: Int64 = 0, income: Int64 = 0
        var expenseSums: CategorySums = [:], incomeSums: CategorySums = [:]
        var unconverted: Set<CurrencyCode> = []
        for r in records where r.status == .posted && r.entryType != .transfer {
            let amount: Int64
            if r.currency == primary {
                amount = r.amountMinor
            } else if let value = try charges.charge(r, to: primary).amountMinor {
                amount = value
            } else {
                unconverted.insert(r.currency)
                continue
            }
            switch r.entryType {
            case .expense:
                let signed = r.isRefund ? -amount : amount
                expense += signed
                let sum = expenseSums[r.categoryID] ?? (0, 0)
                expenseSums[r.categoryID] = (sum.amount + signed, sum.count + 1)
            case .income:
                income += amount
                let sum = incomeSums[r.categoryID] ?? (0, 0)
                incomeSums[r.categoryID] = (sum.amount + amount, sum.count + 1)
            case .transfer: break
            }
        }
        let tree = CategoryTree(categories)
        return MonthStats.ConvertedTotals(
            currency: primary, expenseMinor: expense, incomeMinor: income, unconverted: unconverted.sorted(),
            expenseCategories: categoryTotals(expenseSums, tree: tree), incomeCategories: categoryTotals(incomeSums, tree: tree)
        )
    }

    /// 按大类汇总，大类下面是小类（直接记在大类上的那部分也作为一项）；找不到的分类算待分类。都按金额从大到小
    static func categoryTotals(_ sums: CategorySums, tree: CategoryTree) -> [MonthStats.CategoryTotal] {
        var tops: [String?: MonthStats.CategoryTotal] = [:]
        for (id, sum) in sums {
            guard let category = tree.category(id), let top = tree.topLevel(id) else {
                var entry = tops[nil] ?? .init(categoryID: nil, name: "待分类", symbol: "questionmark.circle", amountMinor: 0, count: 0)
                entry.amountMinor += sum.amount
                entry.count += sum.count
                tops[nil] = entry
                continue
            }
            var entry = tops[top.id] ?? .init(categoryID: top.id, name: top.name, symbol: top.symbol, amountMinor: 0, count: 0)
            entry.amountMinor += sum.amount
            entry.count += sum.count
            entry.children.append(.init(categoryID: category.id, name: category.name, symbol: category.symbol, amountMinor: sum.amount, count: sum.count))
            tops[top.id] = entry
        }
        return tops.values.map { top in
            var top = top
            top.children.sort { $0.amountMinor != $1.amountMinor ? $0.amountMinor > $1.amountMinor : $0.name < $1.name }
            return top
        }
        .sorted { $0.amountMinor != $1.amountMinor ? $0.amountMinor > $1.amountMinor : $0.name < $1.name }
    }
}
