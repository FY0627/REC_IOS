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
    /// 转帐缺少一边，或者转出、转入是同一个账户的同一个币种
    case invalidTransfer
    /// 合成一单至少要两笔，而且都是已入账的同一币种的支出（或收入）
    case invalidOrder
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

    static func withCharges(_ rows: [RecordRow], db: SQLiteConnection, calendar: Calendar) throws -> [RecordRow] {
        guard rows.contains(where: \.isForeignCurrency) else { return rows }
        let calculator = ChargeCalculator(db: db, calendar: calendar)
        return try rows.map { row in
            guard row.isForeignCurrency, let primary = row.accountCurrencies.first else { return row }
            var row = row
            row.charge = try calculator.charge(row.record, primary: primary)
            return row
        }
    }

    /// 修改一笔流水。改了时间：交易时间和接收时间都改成它（影响排序和余额推算）；没改时间则保持原样。
    /// 配对的内部转账：另一边是手动补记的就跟着改（金额、币种、时间），仍是一对；填了到账多少（`edit.peerAmountMinor`）就用填的。
    /// 另一边是银行通知记的：填了到账多少时改它的金额和币种，仍是一对；
    /// 没填时改了账户、金额、币种、方向，或不再是转账类，就不再配对。
    /// 转帐可以换另一边的账户（`edit.peer`）。改了分类：同一单的几笔一起改。转帐不保存分类
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
            // 账户不持有这个币种：保存用户填写的实际扣款（账户主币种）
            if !account.currencies.contains(edit.currency), let minor = edit.settlementMinor, minor > 0 {
                record.settlement = Money(minorUnits: minor, currency: account.currency)
            } else {
                record.settlement = nil
            }
            if let party = edit.transferParty { record.transferParty = party }
            if record.kind != .transferIn, record.kind != .transferOut { record.transferParty = nil }
            if let group = original.transferGroupID {
                let peer = try RecordDAO.inGroup(db, group: group).first { $0.id != id }
                let stillTransfer = record.kind.isTransferLike && record.transferParty != .other
                let toItself = peer?.accountID == record.accountID && (edit.peerCurrency ?? peer?.currency) == record.currency
                let confirmedBankPeer = edit.peer == .keep && edit.peerAmountMinor != nil
                    && original.accountID == record.accountID && original.direction == record.direction
                if let peer, stillTransfer, !toItself, peer.source == .manual || confirmedBankPeer {
                    // 两边原来一样多时，没填到账多少就跟着这一笔；原来不一样（手续费、换汇）时不动
                    let matched = peer.amountMinor == original.amountMinor && peer.currency == original.currency
                    var synced = peer
                    synced.amountMinor = edit.peerAmountMinor ?? (matched ? record.amountMinor : peer.amountMinor)
                    synced.currency = edit.peerCurrency ?? (matched ? record.currency : peer.currency)
                    if synced.amountMinor != peer.amountMinor || synced.currency != peer.currency { synced.settlement = nil }
                    if peer.source == .manual {
                        synced.direction = record.direction.opposite
                        synced.transactionTime = record.transactionTime
                        synced.receivedAt = record.receivedAt
                    }
                    _ = try RecordDAO.update(db, synced)
                } else if !stillTransfer || original.accountID != record.accountID || original.amountMinor != record.amountMinor
                            || original.currency != record.currency || original.direction != record.direction {
                    // 不再是一对：手动补记的另一边没有意义了，删掉；银行通知记的留着
                    if let peer, peer.source == .manual { _ = try RecordDAO.delete(db, id: peer.id) }
                    try RecordDAO.clearTransferGroup(db, group: group)
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
            try RecordDAO.update(db, record)
            if let categoryID = record.categoryID, categoryID != original.categoryID, let group = record.orderGroupID {
                try RecordDAO.setCategory(db, ids: try RecordDAO.inOrderGroup(db, groups: [group]).map(\.id), categoryID: categoryID)
            }
        }
    }

    /// 编辑转帐时换了另一边的账户。先拆开现在的另一边（手动补记的删掉，银行通知记的留着、不再配对），
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
        for peer in current where peer.source == .manual { _ = try RecordDAO.delete(db, id: peer.id) }
        if let group = record.transferGroupID { try RecordDAO.clearTransferGroup(db, group: group) }
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

    /// 给一笔选分类（待分类、详情里改分类），可以顺手写备注。
    /// 没确认对方的转账选了分类就是转给别人。同一单的几笔一起改
    public func setCategory(recordID: String, categoryID: String, note: String? = nil) async throws {
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
            if let note { _ = try RecordDAO.updateNote(db, id: record.id, note: String(note.prefix(500))) }
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

    /// 合并：`id` 的流水改记到 `targetID`，然后删掉 `id`。
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
                    try CategoryDAO.delete(db, id: child.id)
                }
            }
            try RecordDAO.reassignCategory(db, from: [id], to: target.id)
            try CategoryDAO.delete(db, id: id)
            // 自动归类用的标识（例如「工资」）交给目标分类
            if let key = source.autoKey, target.autoKey == nil { try CategoryDAO.setAutoKey(db, id: target.id, autoKey: key) }
        }
    }

    /// 删除分类（连同它的小类）。原来记在上面的流水改记到 `moveRecordsTo`；nil 时回到待分类。记录不删
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
            // 账户没有这个币种：按账户主币种扣款（入账），填了实际金额就存下来，否则按汇率估算
            func record(
                _ account: Account, _ direction: FlowDirection, _ kind: TransactionKind, part: Int, category: String?, settlement: Int64?,
                amount: Int64? = nil, currency: CurrencyCode? = nil
            ) -> LedgerRecord {
                let currency = currency ?? entry.currency
                var settled: Money?
                if !account.currencies.contains(currency), let settlement, settlement > 0 {
                    settled = Money(minorUnits: settlement, currency: account.currency)
                }
                return LedgerRecord(
                    id: newID(), accountID: account.id, amountMinor: amount ?? entry.amountMinor, currency: currency, direction: direction,
                    kind: kind, status: .posted, counterparty: counterparty,
                    transactionTime: time, receivedAt: entry.time, processedAt: now, source: .manual, ingestID: ingestID, partIndex: part,
                    bankReference: nil, balanceAfterMinor: nil, includedFeeMinor: nil, note: String(entry.note.prefix(500)),
                    transferGroupID: nil, relatedRecordID: nil, settlement: settled, categoryID: category
                )
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
                    settlement: entry.settlementMinor
                )]
            case .income:
                records = [record(account, .inflow, .income, part: 0, category: category, settlement: entry.settlementMinor)]
            case .transfer:
                guard let toID = entry.toAccountID, let target = try AccountDAO.find(db, id: toID),
                      toID != account.id || (entry.toCurrency ?? entry.currency) != entry.currency else {
                    throw BackendError.invalidTransfer
                }
                let repayment = target.cardType == .credit && toID != account.id
                records = [
                    record(account, .outflow, repayment ? .repayment : .transferOut, part: 0, category: nil, settlement: entry.settlementMinor),
                    record(
                        target, .inflow, repayment ? .repayment : .transferIn, part: 2, category: nil, settlement: nil,
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
                orderMembers: try Self.decorate(members, db: db, calendar: calendar)
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
                let items = try account.currencies.map { try Self.balanceSummary(db, account: account, currency: $0, charges: charges) }
                result[account.id] = AccountBalances(accountID: account.id, items: items)
            }
            return result
        }
    }

    /// 推算余额：从用户填写的初始余额出发，加上之后到达的已入账流水。没有初始余额时余额未知，不用部分流水冒充。
    /// 主币种还要减去（或加上）这张卡不持有的币种的交易按主币种扣的款；还没有任何汇率、估算不出的不计入。
    /// 银行通知里写的余额不使用：很多银行的通知不带余额，写法和含义也不统一。
    ///
    /// 初始余额是用户在手机上填写的时刻；流水按「通知到达手机的时间」和它比较
    /// （通知内时间是银行所在地的时间，和手机时区可能不同）。
    static func balanceSummary(_ db: SQLiteConnection, account: Account, currency: CurrencyCode, charges: ChargeCalculator) throws -> AccountBalanceSummary {
        guard let opening = account.openingBalance(currency) else {
            return AccountBalanceSummary(accountID: account.id, currency: currency, ledgerDerivedMinor: nil, recordsAfterBase: 0)
        }
        var total = opening.amountMinor
        var count = 0
        var unconverted = 0
        for record in try RecordDAO.postedAfter(db, accountID: account.id, currency: currency) {
            guard (record.receivedAt ?? record.processedAt) > opening.at else { continue }
            total += record.direction == .inflow ? record.amountMinor : -record.amountMinor
            count += 1
        }
        if currency == account.currency {
            for record in try RecordDAO.postedForeign(db, accountID: account.id) {
                guard (record.receivedAt ?? record.processedAt) > opening.at else { continue }
                guard let amount = try charges.charge(record, primary: currency).amountMinor else {
                    unconverted += 1
                    continue
                }
                total += record.direction == .inflow ? amount : -amount
                count += 1
            }
        }
        return AccountBalanceSummary(
            accountID: account.id, currency: currency, ledgerDerivedMinor: total, recordsAfterBase: count,
            openingBalanceMinor: opening.amountMinor, openingBalanceAt: opening.at, unconvertedCount: unconverted
        )
    }

    // MARK: 汇率

    /// 保存快捷指令导入的完整汇率表，按数据源的更新日期一天一份（同一天保留最后下载的）。
    /// 外币交易按交易当天的汇率估算扣款；以前的日期都保留。
    @discardableResult
    public func saveExchangeRates(_ rates: ExchangeRates) async throws -> Bool {
        let day = RateDay.key(rates.updatedAt, calendar: calendar)
        return try await database.write { try RateDAO.save($0, day: day, rates: rates) }
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
            } else if let value = try charges.charge(r, primary: primary).amountMinor {
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
