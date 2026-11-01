import Foundation
import BKModel
import BKDatabase

/// 账户匹配：尾号 + 银行 + 快捷指令绑定的账户；没写尾号的通知记到发通知的钱包，或者这家银行唯一的一张卡。冲突时不强行入账。
enum AccountMatcher {
    enum Result: Equatable {
        case matched(Account)
        case ambiguous([Account])
        /// 正文没有尾号，只有绑定账户可作为候选（需要用户确认）
        case boundOnly(Account)
        case none
    }

    static func match(tail: String?, bankHint: String?, walletHint: String? = nil, boundAccountID: String?, accounts: [Account]) -> Result {
        // 现金、电子钱包没有卡号，不参与尾号匹配
        let active = accounts.filter { !$0.archived && $0.isCard }
        let bound = boundAccountID.flatMap { id in active.first { $0.id == id } }
        // 钱包发的、但用户把它加成了卡（Maya 有卡号）：和银行一样按发通知的机构找
        let issuer = bankHint ?? walletHint
        let bankName = BankCatalog.entry(id: issuer)?.name
        func bankCompatible(_ account: Account) -> Bool {
            guard let bankHint, let bankID = account.bankID else { return true }
            return bankID == bankHint || account.bankName == bankName
        }
        guard let tail else {
            // 支付宝、微信支付发的、没写卡号的：是钱包余额的收支。一般只有一个钱包账户，直接记；有小号时让用户选。
            // 写了卡号尾号的是用银行卡付的，按尾号记到卡上（银行自己的通知也会来，按重复合并）
            if let walletHint {
                let wallets = accounts.filter { !$0.archived && WalletDirectory.provider(of: $0) == walletHint }
                if let bound = wallets.first(where: { $0.id == boundAccountID }) { return .matched(bound) }
                switch wallets.count {
                case 0: break
                case 1: return .matched(wallets[0])
                default: return .ambiguous(wallets)
                }
            }
            // 认出了银行：众安的转账通知不写卡号，这家银行只添加了一张卡时就是这张，有几张时让用户选
            let sameBank = active.filter { issuer != nil && ($0.bankID == issuer || $0.bankName == bankName) }
            if sameBank.count == 1 { return .matched(sameBank[0]) }
            if let bound, bankCompatible(bound) { return .boundOnly(bound) }
            return sameBank.isEmpty ? .none : .ambiguous(sameBank)
        }
        let sameTail = active.filter { $0.matches(tail: tail) }
        if let bound, sameTail.contains(bound) { return .matched(bound) }
        let candidates = sameTail.filter(bankCompatible)
        switch candidates.count {
        case 0: return sameTail.isEmpty ? .none : .ambiguous(sameTail)
        case 1: return .matched(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}

/// 一次入账在数据库事务里的全部步骤。所有函数都在 `Database.write` 的闭包里执行。
struct IngestEngine {
    let db: SQLiteConnection
    let now: Date
    let calendar: Calendar
    let newID: @Sendable () -> String

    struct IngestMeta {
        var ingestID: String
        var source: SourceKind
        var receivedAt: Date?
        var processedAt: Date
    }

    enum CommitOutcome: Equatable {
        case recorded(String)
        case merged(String)
        case pending(PendingReason, candidates: [String], duplicateOf: String?)
    }

    static let retentionKey = "raw_retention_days"
    static let defaultRetentionDays = 30

    func retentionDays() throws -> Int {
        try SettingsDAO.get(db, Self.retentionKey).flatMap(Int.init) ?? Self.defaultRetentionDays
    }

    // MARK: 入口

    func run(_ request: IngestRequest) throws -> IngestResult {
        let normalized = TextNormalizer.normalize(request.text)
        let receivedPart = request.receivedAt.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""
        let fingerprint = SHA256.hex([
            request.source.rawValue,
            request.messageID.map { "id:" + $0 } ?? normalized,
            request.sender ?? "",
            request.subject ?? "",
            receivedPart,
        ].joined(separator: "\u{1F}"))

        if try IngestDAO.exists(db, fingerprint: fingerprint) != nil {
            return IngestResult(ingestID: nil, outcome: .duplicateInput, classification: .transaction, recordedCount: 0, mergedCount: 0, pendingCount: 0, summary: "重复的输入，已忽略")
        }

        let ingestID = newID()
        var parsed = MessageParser.parse(MessageContext(
            text: request.text, source: request.source, sender: request.sender, subject: request.subject,
            referenceDate: request.receivedAt ?? now, calendar: calendar
        ))
        // 用户在本机做的模板优先于通用读法：认得出时只用它认出的这一笔（验证码除外）
        var templateHit = false
        if parsed.classification != .verificationCode, parsed.classification != .empty,
           let found = MessageTemplates.firstHit(try TemplateDAO.all(db), in: parsed.cleanedText) {
            parsed.events = [ParsedEvent(draft: MessageTemplates.draft(found.hit, template: found.template, parsed: parsed, partIndex: 0), issue: nil)]
            parsed.classification = .transaction
            templateHit = true
        }
        let accounts = try AccountDAO.all(db)
        // 固定写法认不出尾号时，在正文里找已添加的卡的尾号；再找卡片信息里填的账号、完整卡号
        // 电子钱包发的不找：里面的四位数字（订单号、金额）不是卡号
        let fallbackTail = parsed.walletHint != nil ? nil
            : Self.knownTail(in: parsed.cleanedText, accounts: accounts) ?? Self.identifierTail(in: parsed.cleanedText, accounts: accounts)

        // 自动化可以对所有短信 / 邮件 / App 通知触发，先筛掉不是动账的：
        // 对得上自己的卡，或者是已添加的钱包发的（以及绑定了账户、用户模板认出的）：往下走正常识别；
        // 对不上时，有非银行的【署名】直接丢；没有署名的，能完整认出交易才留下（被截断的通知可能丢了银行名称，
        // 「你已成功转账 … HKD275.40」这样的仍进待处理，朋友发来的「转我100元」不进）；
        // 银行或钱包发的有金额的留下（可能有卡没添加），没有金额的只留在接收日志里（`logOnly`）。
        // 钱包的其他通知很多，没有金额的照样不保存。
        // 正文提到了已添加账户的银行或钱包（`namedAccounts`），或者金额写得像银行通知（`formalAmount`），也留下：宁可让用户看一眼，不悄悄丢掉
        let ownCard = accounts.filter { !$0.archived && $0.isCard }
        let ownAccount = templateHit || request.boundAccountID != nil || fallbackTail != nil
            || parsed.cardTails.contains { tail in ownCard.contains { $0.matches(tail: tail) } }
            || accounts.contains { !$0.archived && parsed.walletHint != nil && WalletDirectory.provider(of: $0) == parsed.walletHint }
        let named = parsed.hasAmount ? Self.namedAccounts(in: parsed.cleanedText, accounts: accounts) : []
        var classification = parsed.classification
        if !ownAccount, parsed.nonBankSignature {
            classification = .noFinancialContent
        } else if !ownAccount, [MessageClassification.transaction, .unrecognized, .marketing].contains(classification),
                  parsed.bankHint == nil, !parsed.bankSignature, parsed.walletHint == nil || parsed.events.isEmpty,
                  named.isEmpty, !Lexicon.bankish.test(parsed.cleanedText), !parsed.events.contains(where: { $0.issue == nil || Self.formalAmount($0.draft.amount) }) {
            classification = .noFinancialContent
        }
        let logOnly = !ownAccount && !parsed.hasAmount
        // 不是动账通知的不保存，也不写接收日志：普通短信、邮件不会留在 App 里
        if classification == .noFinancialContent {
            return IngestResult(ingestID: nil, outcome: .filtered, classification: classification, recordedCount: 0, mergedCount: 0, pendingCount: 0, summary: classification.displayName)
        }

        let retention = try retentionDays()
        // 验证码和空输入不保存正文；其余按保留期限保存，便于核对和处理待处理项
        let storeRaw = classification != .verificationCode && classification != .empty
        let rawText = storeRaw ? String(request.text.prefix(20_000)) : nil
        let purgeAfter = storeRaw ? now.addingTimeInterval(Double(retention) * 86_400) : nil
        try IngestDAO.insert(
            db, id: ingestID, fingerprint: fingerprint, request: request, processedAt: now, rawText: rawText,
            rawPurgeAfter: purgeAfter, classification: classification, outcome: .filtered, detail: "", parserVersion: MessageParser.version
        )
        let meta = IngestMeta(ingestID: ingestID, source: request.source, receivedAt: request.receivedAt, processedAt: now)

        var recorded = 0, merged = 0, pending = 0
        var items: [IngestItem] = []
        if classification == .transaction {
            for event in parsed.events {
                var draft = event.draft
                if draft.cardTail == nil { draft.cardTail = fallbackTail }
                // 同时写了账号和卡号（「Account XX01 Card XX02」），用户加的可能是其中任何一个
                if let tail = draft.cardTail, !ownCard.contains(where: { $0.matches(tail: tail) }),
                   let other = parsed.cardTails.first(where: { tail in ownCard.contains { $0.matches(tail: tail) } }) {
                    draft.cardTail = other
                }
                let outcome: CommitOutcome
                if let issue = event.issue {
                    let candidates = candidateIDs(for: draft, request: request, accounts: accounts)
                    outcome = .pending(issue, candidates: candidates, duplicateOf: nil)
                } else {
                    outcome = try commit(draft, meta: meta, boundAccountID: request.boundAccountID, accounts: accounts, forcedAccount: nil, duplicateCheck: true)
                }
                switch outcome {
                case let .recorded(recordID):
                    recorded += 1
                    items.append(try item(recordID: recordID, draft: draft, result: .recorded, accounts: accounts))
                case let .merged(recordID):
                    merged += 1
                    items.append(try item(recordID: recordID, draft: draft, result: .merged, accounts: accounts))
                case let .pending(reason, candidates, duplicateOf):
                    // 没有卡号和署名、只是正文提到账户名称：证据不够直接入账，把它列成候选
                    let candidates = candidates.isEmpty ? named.map(\.id) : candidates
                    try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: draft.partIndex, reason: reason, draft: draft, candidates: candidates, duplicateOf: duplicateOf, now: now)
                    pending += 1
                    items.append(Self.pendingItem(draft, reason: reason))
                }
            }
        } else if classification == .unrecognized, !logOnly {
            try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: 0, reason: .unrecognized, draft: nil, candidates: request.boundAccountID.map { [$0] } ?? [], duplicateOf: nil, now: now)
            pending += 1
            items.append(IngestItem(cardTail: nil, kind: nil, status: nil, amountMinor: nil, currency: nil, amountText: nil, result: .pending(.unrecognized)))
        }

        // 只有余额、没有交易：不入账，也不保存余额（卡片余额只从初始余额推算）；能对上卡时记为这张卡收到过自动输入
        for balance in parsed.balances {
            guard case let .matched(account) = AccountMatcher.match(
                tail: balance.cardTail, bankHint: parsed.bankHint, walletHint: parsed.walletHint, boundAccountID: request.boundAccountID, accounts: accounts
            ) else { continue }
            try AccountDAO.noteSuccess(db, id: account.id, at: now, source: request.source)
        }

        let outcome: IngestOutcome
        if pending > 0 { outcome = .pending }
        else if recorded > 0 { outcome = .recorded }
        else if merged > 0 { outcome = .mergedDuplicate }
        else { outcome = .filtered }

        var parts: [String] = []
        if recorded > 0 { parts.append("入账 \(recorded) 笔") }
        if merged > 0 { parts.append("与已有流水合并 \(merged) 笔") }
        if pending > 0 { parts.append("待处理 \(pending) 条") }
        if parts.isEmpty { parts.append(classification.displayName) }
        let summary = parts.joined(separator: "，")
        // 待处理项的正文要保留到处理完；其余按保留期限清理
        try IngestDAO.updateResult(db, id: ingestID, classification: classification, outcome: outcome, detail: summary, rawPurgeAfter: purgeAfter)
        return IngestResult(ingestID: ingestID, outcome: outcome, classification: classification, recordedCount: recorded, mergedCount: merged, pendingCount: pending, summary: summary, items: items)
    }

    /// 已入账 / 已合并的一笔：用流水本身的金额、币种和账户尾号
    private func item(recordID: String, draft: EventDraft, result: IngestItem.Result, accounts: [Account]) throws -> IngestItem {
        guard let record = try RecordDAO.find(db, id: recordID) else {
            return Self.pendingItem(draft, result: result)
        }
        let tail = accounts.first { $0.id == record.accountID }?.last4 ?? draft.cardTail
        return IngestItem(cardTail: tail, kind: record.kind, status: record.status, amountMinor: record.amountMinor, currency: record.currency, amountText: nil, result: result)
    }

    /// 没有入账的一笔：只有通知里写的尾号和金额原文
    static func pendingItem(_ draft: EventDraft, reason: PendingReason) -> IngestItem {
        pendingItem(draft, result: .pending(reason))
    }

    private static func pendingItem(_ draft: EventDraft, result: IngestItem.Result) -> IngestItem {
        let candidates = draft.amount.currencyCandidates
        let currency = draft.amount.preferredCurrency ?? (candidates.count == 1 ? candidates[0] : nil)
        return IngestItem(cardTail: draft.cardTail, kind: draft.kind, status: draft.status, amountMinor: nil, currency: currency, amountText: draft.amount.digits, result: result)
    }

    /// 正文里没认出尾号时，找已添加的卡的尾号：作为单独的 4 位数字出现、并且只有一张卡的尾号出现时，就是这张卡。
    /// 各家银行、各种语言写尾号的方式不同（「結尾號碼1234」「a/c XX1234」），这样不依赖固定写法。
    /// 排除明显不是尾号的位置：更长数字的一部分、日期（2026年、16/03/2026）、金额（CNY1234、1234元、1234.00）、
    /// 引号里的转账对象（`转出至"100*0001"` 不是自己的卡）。
    static func knownTail(in text: String, accounts: [Account]) -> String? {
        let text = MessageParser.quoted.replace(MessageParser.maskedPhone.replace(text, with: " "), with: " ")
        let tails = Set(accounts.filter { !$0.archived && $0.isCard }.map(\.last4)).filter { $0.count == 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        var found = tails.filter { tail in
            text.range(of: "(?<![0-9/.:$¥€£A-WYZa-wyz-])\(tail)(?![0-9年月日元圆号]|[.,][0-9])", options: .regularExpression) != nil
        }
        // 出现多个时，像年份的（「24 Oct 2026」）不算
        if found.count > 1 { found = found.filter { !(1990...2099).contains(Int($0) ?? 0) } }
        return found.count == 1 ? found.first : nil
    }

    /// 正文提到了哪些已添加账户的银行或钱包。认的是用户添加的账户，所以不限于名录里的机构。
    /// 英文按整个单词比较，不到 4 个字母的简称（ZA、ABC）和不到 3 个字的中文（平安）太容易撞上普通文字，不算
    static func namedAccounts(in text: String, accounts: [Account]) -> [Account] {
        accounts.filter { account in
            guard !account.archived, account.isCard || account.cardType == .wallet else { return false }
            let entry = BankCatalog.entry(id: account.bankID)
            let names = [account.bankName, entry?.localName].compactMap { $0 } + (entry?.aliases ?? [])
            return names.contains { name in
                let ascii = name.allSatisfy(\.isASCII)
                guard name.count >= (ascii ? 4 : 3) else { return false }
                let pattern = NSRegularExpression.escapedPattern(for: name)
                return text.range(of: ascii ? "(?<![A-Za-z0-9])\(pattern)(?![A-Za-z0-9])" : pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }

    /// 写了明确的币种和两位小数（`PHP 200.00`）：银行和钱包的写法，朋友发的「转我100元」不是这样
    static func formalAmount(_ amount: AmountText) -> Bool {
        amount.currencyCandidates.count == 1 && amount.digits.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil
    }

    /// 通知里写的是账号（户口号码）或完整卡号时，和卡片信息里填写的号码比较。
    /// 通知里的号码常被打码（`100-200XXX-300`）：两边的 X、*、• 都当作任意一位数字。
    /// 只有一张卡对得上时返回它的尾号。
    static func identifierTail(in text: String, accounts: [Account]) -> String? {
        let tokens = numberTokens(in: text)
        guard !tokens.isEmpty else { return nil }
        let matched = accounts.filter { account in
            guard !account.archived, account.isCard else { return false }
            let ids = [account.accountNumber, account.cardNumber].compactMap { $0 }.map(Account.numberPattern)
            return ids.contains { id in tokens.contains { maskedMatch($0, id) } }
        }
        return matched.count == 1 ? matched[0].last4 : nil
    }

    private static let numberToken = Rx(#"[0-9Xx*•](?:[0-9Xx*•]|-(?=[0-9Xx*•]))+"#)

    /// 正文里像号码的片段（数字、打码位、短横线），整理成只有数字和 X；至少 6 位、其中至少 3 位数字
    static func numberTokens(in text: String) -> [String] {
        let ns = NSString(string: text)
        return numberToken.matches(ns)
            .map { Account.numberPattern(ns.substring(with: $0.range)) }
            .filter { $0.count >= 6 && $0.filter(\.isNumber).count >= 3 }
    }

    /// 等长时逐位比较；通知里的号码更短且以打码位开头时（`XXXX300`）和完整号码的末尾比较
    static func maskedMatch(_ token: String, _ id: String) -> Bool {
        let t = Array(token), full = Array(id)
        let aligned: ArraySlice<Character>
        if t.count == full.count {
            aligned = full[...]
        } else if t.count < full.count, t.first == "X" {
            aligned = full.suffix(t.count)
        } else {
            return false
        }
        return zip(t, aligned).allSatisfy { $0 == $1 || $0 == "X" || $1 == "X" }
    }

    /// 刚保存的模板用于还没处理的待处理项：认得出的通知按模板重新入账，或者换成新的待处理原因（例如还要选卡）；
    /// 这条通知原来的待处理项关闭。已经有流水入账的通知不动，避免重复记账。返回重新识别的通知条数。
    func reapply(_ template: MessageTemplate) throws -> Int {
        let accounts = try AccountDAO.all(db)
        var count = 0
        for (ingestID, items) in Dictionary(grouping: try PendingDAO.open(db), by: \.ingestID) {
            guard let first = items.first, let raw = first.rawText, try !PendingDAO.ingestHasRecords(db, ingestID: ingestID),
                  let meta = try IngestDAO.meta(db, id: ingestID) else { continue }
            let parsed = MessageParser.parse(MessageContext(
                text: raw, source: meta.source, sender: meta.sender, subject: nil,
                referenceDate: meta.receivedAt ?? meta.processedAt, calendar: calendar
            ))
            guard let hit = MessageTemplates.match(template, in: parsed.cleanedText) else { continue }
            var draft = MessageTemplates.draft(hit, template: template, parsed: parsed, partIndex: try PendingDAO.nextPartIndex(db, ingestID: ingestID))
            if draft.cardTail == nil, draft.walletHint == nil {
                draft.cardTail = Self.knownTail(in: parsed.cleanedText, accounts: accounts) ?? Self.identifierTail(in: parsed.cleanedText, accounts: accounts)
            }
            for item in items { _ = try PendingDAO.resolve(db, id: item.id, status: .ignored, at: now) }
            let outcome = try commit(
                draft, meta: IngestMeta(ingestID: ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                boundAccountID: nil, accounts: accounts, forcedAccount: nil, duplicateCheck: true
            )
            if case let .pending(reason, candidates, duplicateOf) = outcome {
                try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: draft.partIndex, reason: reason, draft: draft, candidates: candidates, duplicateOf: duplicateOf, now: now)
            }
            count += 1
        }
        return count
    }

    func candidateIDs(for draft: EventDraft, request: IngestRequest, accounts: [Account]) -> [String] {
        switch AccountMatcher.match(tail: draft.cardTail, bankHint: draft.bankHint, walletHint: draft.walletHint, boundAccountID: request.boundAccountID, accounts: accounts) {
        case let .matched(a): [a.id]
        case let .ambiguous(list): list.map(\.id)
        case let .boundOnly(a): [a.id]
        case .none: []
        }
    }

    // MARK: 草稿 → 记录

    /// 通知没写币种、或只写了「元」这类含糊写法时记为账户主币种；
    /// 否则优先取账户持有的币种（多币种账户里「¥」「$」等写法据此区分）。
    func resolveCurrency(_ amount: AmountText, account: Account) -> CurrencyCode? {
        let candidates = amount.currencyCandidates
        if candidates.isEmpty || candidates.contains(account.currency) { return account.currency }
        let held = account.currencies
        if let preferred = amount.preferredCurrency, candidates.contains(preferred), held.contains(preferred) { return preferred }
        if let match = held.first(where: candidates.contains) { return match }
        if candidates.count == 1 { return candidates[0] }
        return amount.preferredCurrency
    }

    /// 把一份完整草稿写成记录；需要用户介入时返回 `.pending`，不写记录。
    func commit(_ draft: EventDraft, meta: IngestMeta, boundAccountID: String?, accounts: [Account], forcedAccount: Account?, duplicateCheck: Bool, forcedDedupeKey: String? = nil) throws -> CommitOutcome {
        let account: Account
        if let forcedAccount {
            account = forcedAccount
        } else {
            switch AccountMatcher.match(tail: draft.cardTail, bankHint: draft.bankHint, walletHint: draft.walletHint, boundAccountID: boundAccountID, accounts: accounts) {
            case let .matched(a): account = a
            case let .ambiguous(list): return .pending(.ambiguousAccount, candidates: list.map(\.id), duplicateOf: nil)
            case let .boundOnly(a): return .pending(.missingCardTail, candidates: [a.id], duplicateOf: nil)
            case .none: return .pending(draft.cardTail == nil ? .missingCardTail : .noMatchingAccount, candidates: [], duplicateOf: nil)
            }
        }

        guard let currency = resolveCurrency(draft.amount, account: account) else {
            return .pending(.unknownCurrency, candidates: [account.id], duplicateOf: nil)
        }
        let exponent = currency.minorUnitExponent
        guard case var .success(amountMinor) = AmountParser.minorUnits(draft.amount.digits, exponent: exponent) else {
            return .pending(.ambiguousAmount, candidates: [account.id], duplicateOf: nil)
        }
        var includedFeeMinor: Int64?
        if let fee = draft.includedFee {
            guard case let .success(feeMinor) = AmountParser.minorUnits(fee.digits, exponent: exponent), feeMinor < amountMinor else {
                return .pending(.ambiguousAmount, candidates: [account.id], duplicateOf: nil)
            }
            includedFeeMinor = feeMinor
            amountMinor -= feeMinor
        }
        var balanceMinor: Int64?
        if let balance = draft.balanceAfter, resolveCurrency(balance, account: account) == currency,
           case let .success(value) = AmountParser.minorUnits(balance.digits, exponent: exponent) {
            balanceMinor = value
        }
        let direction: FlowDirection
        if let explicit = draft.direction {
            direction = explicit
        } else if draft.kind == .repayment {
            direction = account.cardType == .credit ? .inflow : .outflow
        } else {
            return .pending(.uncertainKind, candidates: [account.id], duplicateOf: nil)
        }

        // 通知写明的实际扣款：只有账户不持有交易币种、扣的是主币种时才用得上（和用户手动填的一样，见 `ChargeCalculator`）
        var settlement: Money?
        if let written = draft.settlement, !account.currencies.contains(currency), resolveCurrency(written, account: account) == account.currency,
           case let .success(minor) = AmountParser.minorUnits(written.digits, exponent: account.currency.minorUnitExponent), minor > 0 {
            settlement = Money(minorUnits: minor, currency: account.currency)
        }

        let record = LedgerRecord(
            id: newID(), accountID: account.id, amountMinor: amountMinor, currency: currency, direction: direction,
            kind: draft.kind, status: draft.status, counterparty: draft.counterparty, transactionTime: draft.transactionTime,
            receivedAt: meta.receivedAt, processedAt: meta.processedAt, source: meta.source, ingestID: meta.ingestID,
            partIndex: draft.partIndex, bankReference: draft.bankReference, balanceAfterMinor: balanceMinor,
            includedFeeMinor: includedFeeMinor, note: "", transferGroupID: nil, relatedRecordID: nil, settlement: settlement
        )

        let key = forcedDedupeKey ?? dedupeKey(record)
        if let existingID = try RecordDAO.idForDedupeKey(db, key), let existing = try RecordDAO.find(db, id: existingID) {
            // 同一笔交易的另一来源（短信 + 邮件 + App 通知），证据充分：合并为来源证据。
            // 来源分不出（一个自动化接收全部）时，同一来源的同一条输入已由指纹去重，这里视为另一来源
            if existing.source != meta.source || meta.source == .auto || !duplicateCheck {
                try RecordDAO.addEvidence(db, recordID: existingID, ingestID: meta.ingestID, source: meta.source, at: now)
                try AccountDAO.noteSuccess(db, id: account.id, at: now, source: meta.source)
                return .merged(existingID)
            }
            // 同一来源、内容不同但特征一致：可能是两笔真实交易，交给用户判断
            return .pending(.possibleDuplicate, candidates: [account.id], duplicateOf: existingID)
        }
        if duplicateCheck, let similar = try possibleDuplicate(of: record) {
            return .pending(.possibleDuplicate, candidates: [account.id], duplicateOf: similar.id)
        }
        guard try RecordDAO.insertIfAbsent(db, record, dedupeKey: key, now: now) else {
            // 事务内不会发生；保守处理为合并
            let existingID = try RecordDAO.idForDedupeKey(db, key) ?? record.id
            try RecordDAO.addEvidence(db, recordID: existingID, ingestID: meta.ingestID, source: meta.source, at: now)
            return .merged(existingID)
        }
        try RecordDAO.addEvidence(db, recordID: record.id, ingestID: meta.ingestID, source: meta.source, at: now)
        try AccountDAO.noteSuccess(db, id: account.id, at: now, source: meta.source)
        try linkTransfer(record, counterpartyTail: draft.counterpartyTail, accounts: accounts)
        try linkRefund(record)
        try closeHold(of: record, holdTime: draft.holdTime)
        try Categorizer(db: db).categorize(recordID: record.id)
        return .recorded(record.id)
    }

    /// 去重键：可信交易标识 > 精确到分钟的交易时间 + 金额特征 > 本次输入内唯一。
    func dedupeKey(_ r: LedgerRecord) -> String {
        let role = r.partIndex % 2 == 1 ? "fee" : "main"
        if let reference = r.bankReference {
            return ["ref", r.accountID, reference, role].joined(separator: "|")
        }
        if let time = r.transactionTime, time.isMinutePrecise {
            return ["t", r.accountID, r.direction.rawValue, String(r.amountMinor), r.currency.rawValue, r.kind.rawValue, r.status.rawValue, time.sortKey, r.balanceAfterMinor.map(String.init) ?? "-", role].joined(separator: "|")
        }
        return ["i", r.ingestID, String(r.partIndex)].joined(separator: "|")
    }

    /// 跨来源的近似重复：同账户、同金额币种方向，来源不同（或分不出来源）、系统时间 20 分钟内，且正文时间不冲突。
    /// 手动记过的一笔：时间是用户随手选的，前后 3 小时内同卡同金额就问是不是同一笔。
    func possibleDuplicate(of record: LedgerRecord) throws -> LedgerRecord? {
        let window: TimeInterval = 20 * 60
        let candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        )
        let similar = candidates.first { other in
            guard other.accountID == record.accountID, other.status == record.status,
                  other.source != record.source || record.source == .auto else { return false }
            if other.source == .manual { return true }
            if let a = other.transactionTime, let b = record.transactionTime, a.isMinutePrecise, b.isMinutePrecise, a.sortKey != b.sortKey { return false }
            if let a = other.balanceAfterMinor, let b = record.balanceAfterMinor, a != b { return false }
            return true
        }
        if let similar { return similar }
        guard record.source != .manual else { return nil }
        let manualWindow: TimeInterval = 3 * 3600
        return try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-manualWindow), effectiveTo: record.effectiveAt.addingTimeInterval(manualWindow),
            excludingIngest: record.ingestID
        ).first { $0.source == .manual && $0.accountID == record.accountID && $0.status == record.status }
    }

    /// 自己两张卡之间的转账：两边流水都保留，可靠关联时标记同一转账组。
    func linkTransfer(_ record: LedgerRecord, counterpartyTail: String?, accounts: [Account]) throws {
        guard record.status == .posted, record.kind.isTransferLike else { return }
        let peerAccounts = counterpartyTail.map { tail in accounts.filter { $0.isCard && $0.matches(tail: tail) && $0.id != record.accountID && !$0.archived } } ?? []
        let window: TimeInterval = 30 * 60
        var candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction.opposite,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        ).filter { $0.accountID != record.accountID && $0.status == .posted && $0.kind.isTransferLike }
        candidates = try candidates.filter { candidate in
            guard let group = candidate.transferGroupID else { return true }
            return try RecordDAO.inGroup(db, group: group).count == 1
        }
        if !peerAccounts.isEmpty {
            let preferred = candidates.filter { c in peerAccounts.contains { $0.id == c.accountID } }
            if !preferred.isEmpty { candidates = preferred }
        }
        if candidates.count == 1 {
            let peer = candidates[0]
            let group = peer.transferGroupID ?? newID()
            try RecordDAO.setTransferGroup(db, ids: [record.id, peer.id], group: group)
        } else if candidates.isEmpty, peerAccounts.count == 1 {
            // 正文明确写了对方是自己的另一张卡，但对方的通知还没到：先单边标记为内部转账
            try RecordDAO.setTransferGroup(db, ids: [record.id], group: newID())
        }
    }

    /// 退款 / 冲正：能唯一找到原交易时建立关联，原交易保持不变。
    func linkRefund(_ record: LedgerRecord) throws {
        guard record.direction == .inflow, record.kind == .refund || record.kind == .reversal, let counterparty = record.counterparty else { return }
        let origins = try RecordDAO.refundOriginCandidates(
            db, accountID: record.accountID, counterparty: counterparty, minAmount: record.amountMinor, currency: record.currency,
            before: record.effectiveAt, after: record.effectiveAt.addingTimeInterval(-180 * 86_400)
        ).filter { $0.id != record.id }
        if origins.count == 1 { try RecordDAO.setRelated(db, id: record.id, relatedID: origins[0].id) }
    }

    /// 完成扣款：通知写明了之前那笔预授权的时间。同一张卡上只有一笔冻结是这个时间（精确到分钟）时，它已经了结，
    /// 不再显示「冻结」，并关联到这笔扣款。不比较金额：最终扣款可以和冻结金额不同，币种也常常不同。
    func closeHold(of record: LedgerRecord, holdTime: WallClock?) throws {
        guard record.status == .posted, let holdTime, holdTime.isMinutePrecise else { return }
        let holds = try RecordDAO.holds(db, accountID: record.accountID).filter { $0.transactionTime?.sortKey.hasPrefix(holdTime.sortKey) == true }
        guard holds.count == 1 else { return }
        try RecordDAO.setStatus(db, id: holds[0].id, status: .holdReleased)
        try RecordDAO.setRelated(db, id: holds[0].id, relatedID: record.id)
    }

    func orderKey(time: WallClock?, fallback: Date) -> String {
        if let time, time.year != nil, time.hasDate { return time.sortKey }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fallback)
        return WallClock(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second).sortKey
    }
}
