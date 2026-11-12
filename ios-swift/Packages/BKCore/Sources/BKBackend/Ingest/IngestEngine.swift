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
        // 同一条通知连着交过来几遍时只留一遍：和只交一遍的是同一条输入（指纹相同），不会认成同一句里的几个金额
        var request = request
        request.text = TextNormalizer.singleCopy(request.text)
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
        return try process(request, ingestID: newID(), fingerprint: fingerprint, processedAt: now)
    }

    /// 识别一条输入并入账。`fingerprint` 是 nil 时是重读一条已经保存的输入（`rereadPending`）：不再插入，只更新它的结果，
    /// `processedAt` 是它原来的处理时间
    private func process(_ request: IngestRequest, ingestID: String, fingerprint: String?, processedAt: Date) throws -> IngestResult {
        // 付款页截图（ADR 0021）走自己的解析：认页面、按标签读，不按银行通知的写法
        let screenshot = request.source == .screenshot
            ? ScreenshotParser.parse(request.text, referenceDate: request.receivedAt ?? processedAt, calendar: calendar) : nil
        var parsed = screenshot?.message ?? MessageParser.parse(MessageContext(
            text: request.text, source: request.source, sender: request.sender, subject: request.subject,
            referenceDate: request.receivedAt ?? processedAt, calendar: calendar
        ))
        // 用户在本机做的模板优先于通用读法：认得出时只用它认出的这一笔（验证码除外）。
        // 用户点过「不记」的写法最先看：认得出就整条不记
        var templateHit = false
        let templates = parsed.classification != .verificationCode && parsed.classification != .empty ? try TemplateDAO.all(db) : []
        if MessageTemplates.skips(templates, in: parsed.cleanedText) {
            parsed.classification = .skipped
            parsed.events = []
            parsed.balances = []
        } else if let found = MessageTemplates.firstHit(templates, in: parsed.cleanedText) {
            parsed.events = [ParsedEvent(draft: MessageTemplates.draft(found.hit, template: found.template, parsed: parsed, partIndex: 0), issue: nil)]
            parsed.classification = .transaction
            templateHit = true
        }
        let accounts = try AccountDAO.all(db)
        // 固定写法认不出尾号时，在正文里找已添加的卡的尾号；再找卡片信息里填的账号、完整卡号
        // 电子钱包发的不找：里面的四位数字（订单号、金额）不是卡号
        // 截图上的数字多半是单号和时间，也不找
        let fallbackTail = parsed.walletHint != nil || screenshot != nil ? nil
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
        if screenshot != nil {
            // 用户自己交的截图：认不出是付款页的不记（解析时已经判断），不按银行通知的规则筛
            if classification == .empty { classification = .noFinancialContent }
        } else if !ownAccount, parsed.nonBankSignature {
            classification = .noFinancialContent
        } else if !ownAccount, [MessageClassification.transaction, .unrecognized, .marketing].contains(classification),
                  parsed.bankHint == nil, !parsed.bankSignature, parsed.walletHint == nil || parsed.events.isEmpty,
                  named.isEmpty, !Lexicon.bankish.test(parsed.cleanedText), !parsed.events.contains(where: { Self.credible($0, nameAndAmountOnly: parsed.nameAndAmountOnly) }) {
            classification = .noFinancialContent
        }
        let logOnly = screenshot == nil && !ownAccount && !parsed.hasAmount
        // 不是动账通知的不保存，也不写接收日志：普通短信、邮件不会留在 App 里
        if classification == .noFinancialContent {
            // 重读时才发现不是动账通知：以前保存的正文清掉
            if fingerprint == nil { try IngestDAO.discard(db, id: ingestID, classification: classification, detail: classification.displayName, parserVersion: MessageParser.version) }
            return IngestResult(ingestID: nil, outcome: .filtered, classification: classification, recordedCount: 0, mergedCount: 0, pendingCount: 0, summary: classification.displayName)
        }

        let retention = try retentionDays()
        // 验证码和空输入不保存正文；其余按保留期限保存，便于核对和处理待处理项
        let storeRaw = classification != .verificationCode && classification != .empty
        let rawText = storeRaw ? String(request.text.prefix(20_000)) : nil
        let purgeAfter = storeRaw ? now.addingTimeInterval(Double(retention) * 86_400) : nil
        if let fingerprint {
            try IngestDAO.insert(
                db, id: ingestID, fingerprint: fingerprint, request: request, processedAt: processedAt, rawText: rawText,
                rawPurgeAfter: purgeAfter, classification: classification, outcome: .filtered, detail: "", parserVersion: MessageParser.version
            )
        } else {
            try IngestDAO.setParserVersion(db, id: ingestID, MessageParser.version, clearRaw: !storeRaw)
        }
        let meta = IngestMeta(ingestID: ingestID, source: request.source, receivedAt: request.receivedAt, processedAt: processedAt)

        var recorded = 0, merged = 0, pending = 0
        var items: [IngestItem] = []
        // 银行 App 的换汇页：两笔都记到同时有这两个币种的账户，记完配成一对（同卡换汇）
        let exchangeRoute = screenshot?.exchange == true && !templateHit ? Self.exchangeRoute(parsed.events.map(\.draft), accounts: accounts) : nil
        var exchangeIDs: [String] = []
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
                let route = exchangeRoute ?? screenshot.map { screenshotRoute(draft, reading: $0, accounts: accounts) }
                if let issue = event.issue {
                    let candidates = route?.candidates ?? candidateIDs(for: draft, request: request, accounts: accounts)
                    outcome = .pending(issue, candidates: candidates, duplicateOf: nil)
                } else if let route, let reason = route.pending {
                    outcome = .pending(reason, candidates: route.candidates, duplicateOf: nil)
                } else {
                    // 换汇的两笔写着同一个交易编号：按单号去重时分开卖出、买入两边
                    var exchangeKey: String?
                    if exchangeRoute != nil, let account = route?.account?.id, let reference = draft.bankReference {
                        exchangeKey = ["ref", account, reference, "fx", draft.direction?.rawValue ?? "-"].joined(separator: "|")
                    }
                    outcome = try commit(
                        draft, meta: meta, boundAccountID: request.boundAccountID, accounts: accounts, forcedAccount: route?.account, duplicateCheck: true,
                        forcedDedupeKey: exchangeKey, assumedAccount: route?.assumed ?? false
                    )
                }
                switch outcome {
                case let .recorded(recordID):
                    recorded += 1
                    if exchangeRoute != nil { exchangeIDs.append(recordID) }
                    items.append(try item(recordID: recordID, draft: draft, result: .recorded, accounts: accounts))
                case let .merged(recordID):
                    merged += 1
                    if exchangeRoute != nil { exchangeIDs.append(recordID) }
                    items.append(try item(recordID: recordID, draft: draft, result: .merged, accounts: accounts))
                case let .pending(reason, candidates, duplicateOf):
                    // 没有卡号和署名、只是正文提到账户名称：证据不够直接入账，把它列成候选
                    let candidates = candidates.isEmpty ? named.map(\.id) : candidates
                    try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: draft.partIndex, reason: reason, draft: draft, candidates: candidates, duplicateOf: duplicateOf, now: now)
                    pending += 1
                    items.append(Self.pendingItem(draft, reason: reason))
                }
            }
            if exchangeIDs.count == 2, exchangeIDs[0] != exchangeIDs[1] { try pairExchange(exchangeIDs) }
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
        let account = accounts.first { $0.id == record.accountID }
        // 支出换成账户的另一个币种扣：通知里写明扣了多少；账户有这个币种还换了，是这个币种的余额不够
        var charge: RecordCharge?
        var insufficient = false
        if let account, record.direction == .outflow, let charged = record.chargedCurrency(in: account.currencies), charged != record.currency {
            charge = try ChargeCalculator(db: db, calendar: calendar).charge(record, to: charged)
            insufficient = account.currencies.contains(record.currency)
        }
        return IngestItem(
            cardTail: account?.last4 ?? draft.cardTail, kind: record.kind, status: record.status, amountMinor: record.amountMinor,
            currency: record.currency, amountText: nil, result: result, recordID: record.id, charge: charge, insufficientBalance: insufficient,
            accountTitle: account.flatMap { $0.isCard ? nil : $0.displayTitle }, counterparty: record.counterparty
        )
    }

    /// 没有入账的一笔：只有通知里写的尾号和金额原文
    static func pendingItem(_ draft: EventDraft, reason: PendingReason) -> IngestItem {
        pendingItem(draft, result: .pending(reason))
    }

    private static func pendingItem(_ draft: EventDraft, result: IngestItem.Result) -> IngestItem {
        let candidates = draft.amount.currencyCandidates
        let currency = draft.amount.preferredCurrency ?? (candidates.count == 1 ? candidates[0] : nil)
        // 钱包的收支没写卡号：通知写钱包的名称
        let wallet = draft.cardTail == nil ? WalletDirectory.profile(id: draft.walletHint)?.name : nil
        return IngestItem(
            cardTail: draft.cardTail, kind: draft.kind, status: draft.status, amountMinor: nil, currency: currency, amountText: draft.amount.digits, result: result,
            accountTitle: wallet, counterparty: draft.counterparty
        )
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

    /// 没有署名、对不上账户的通知里，这一笔够不够算动账通知。完整认出交易的算，但金额要像金额：
    /// 没写币种、也没有小数的一个整数不算（聊天里的「扣了你3次」「补缴1-9月」）；
    /// 只有名称和金额的（Apple 钱包的通知），币种要写得明确（「JP¥」「CN¥」，只写「¥」「$」的不算）
    static func credible(_ event: ParsedEvent, nameAndAmountOnly: Bool) -> Bool {
        let amount = event.draft.amount
        if formalAmount(amount) { return true }
        guard event.issue == nil else { return false }
        if nameAndAmountOnly { return amount.currencyCandidates.count == 1 }
        return !amount.currencyCandidates.isEmpty || amount.digits.range(of: #"[.,]\d{1,3}$"#, options: .regularExpression) != nil
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
        // 写明类型、拆开写：旧版本的编译器推断「"X"」是什么类型太慢，报「表达式太复杂」
        let mask: Character = "X"
        for (a, b) in zip(t, aligned) where a != b && a != mask && b != mask {
            return false
        }
        return true
    }

    /// 读法更新后（`MessageParser.version`），还没处理的待处理项按新读法重读一遍：能入账的入账，不是动账通知的不再保存，
    /// 其余换成新读出来的待处理（金额、币种、方向按新读法）。只重读整条通知都还没处理的：已经有流水入账、
    /// 或者用户记入、忽略过其中一条的不动。截图不重读。返回重读的通知条数
    func rereadPending() throws -> Int {
        var count = 0
        for entry in try IngestDAO.staleWithOpenPending(db, below: MessageParser.version) {
            guard let raw = entry.rawText else { continue }
            let created = try PendingDAO.firstCreatedAt(db, ingestID: entry.id)
            try PendingDAO.deleteAll(db, ingestID: entry.id)
            _ = try process(
                IngestRequest(text: raw, source: entry.source, sender: entry.sender, subject: entry.subject, receivedAt: entry.receivedAt, boundAccountID: entry.boundAccountID),
                ingestID: entry.id, fingerprint: nil, processedAt: entry.processedAt
            )
            // 仍然待处理的留在列表里原来的位置
            if let created { try PendingDAO.setCreatedAt(db, ingestID: entry.id, created) }
            count += 1
        }
        return count
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
    /// `assumedAccount`：截图没写用什么付的，账户是猜的钱包（ADR 0021）
    func commit(
        _ draft: EventDraft, meta: IngestMeta, boundAccountID: String?, accounts: [Account], forcedAccount: Account?, duplicateCheck: Bool,
        forcedDedupeKey: String? = nil, assumedAccount: Bool = false
    ) throws -> CommitOutcome {
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

        // 截图上写了交易时间：按它排在那一天，不按截图的时间
        let receivedAt = meta.source == .screenshot ? (date(of: draft.transactionTime) ?? meta.receivedAt) : meta.receivedAt
        var record = LedgerRecord(
            id: newID(), accountID: account.id, amountMinor: amountMinor, currency: currency, direction: direction,
            kind: draft.kind, status: draft.status, counterparty: draft.counterparty, transactionTime: draft.transactionTime,
            receivedAt: receivedAt, processedAt: meta.processedAt, source: meta.source, ingestID: meta.ingestID,
            partIndex: draft.partIndex, bankReference: draft.bankReference, balanceAfterMinor: balanceMinor,
            includedFeeMinor: includedFeeMinor, note: "", transferGroupID: nil, relatedRecordID: nil
        )
        // 从账户的哪个币种扣（ADR 0018）：账户没有这笔的币种、通知写明了扣的是账户的哪个币种多少（「JPY1000.00（人民币48.00）」）时用它
        // （账户有这个币种时，括号里多半只是折合多少）；
        // 多币种账户这个币种的余额不够这笔消费时，整笔换成主币种扣，按汇率估算（恒生就是这样）；
        // 其余记在这笔自己的币种，账户没有这个币种时按主币种估算（`chargedCurrency(in:)`）
        if let written = draft.settlement, !account.currencies.contains(currency), let writtenCurrency = resolveCurrency(written, account: account),
           account.currencies.contains(writtenCurrency),
           case let .success(minor) = AmountParser.minorUnits(written.digits, exponent: writtenCurrency.minorUnitExponent), minor > 0 {
            record.chargeCurrency = writtenCurrency
            record.settlementMinor = minor
        } else if draft.holdTime == nil, try lacksBalance(record, account: account) {
            record.chargeCurrency = account.currency
            // 括号里写了折合主币种多少：换成主币种扣时，多半就是扣了这么多
            if let written = draft.settlement, resolveCurrency(written, account: account) == account.currency,
               case let .success(minor) = AmountParser.minorUnits(written.digits, exponent: account.currency.minorUnitExponent), minor > 0 {
                record.settlementMinor = minor
            }
        }

        let key = forcedDedupeKey ?? dedupeKey(record)
        if let existingID = try RecordDAO.idForDedupeKey(db, key), let existing = try RecordDAO.find(db, id: existingID) {
            // 截图和别的来源（或者同一笔截了两次）：单号相同、时间到分钟相同，是同一笔
            if meta.source == .screenshot || existing.source == .screenshot {
                return try mergeScreenshot(record, into: existing, meta: meta, assumedAccount: assumedAccount)
            }
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
        if duplicateCheck, let twin = try screenshotTwin(of: record, accounts: accounts, assumedAccount: assumedAccount) {
            return try mergeScreenshot(record, into: twin, meta: meta, assumedAccount: assumedAccount)
        }
        // 同一笔的两条通知，一条写全了、一条只有卡号和金额（招行 App 的推送）：合成一笔，补上时间和商户，再了结冻结
        if duplicateCheck, let twin = try detailTwin(of: record) {
            return try mergeDetail(record, into: twin, dedupeKey: key, holdTime: draft.holdTime, meta: meta)
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

    /// 多币种账户的消费：这个币种的可用余额（推算余额减还没结清的冻结）不够这一笔，银行会整笔换成主币种扣（ADR 0018）。
    /// 只看非信用卡账户里不是主币种的持有币种；这个币种余额未知时不判断。
    /// 完成之前预授权的那笔（通知写了预授权时间）不判断：冻结时银行已经扣起，那笔冻结还没关掉，算进去会重复
    func lacksBalance(_ record: LedgerRecord, account: Account) throws -> Bool {
        guard account.isMultiCurrency, account.cardType != .credit, record.direction == .outflow, record.kind == .purchase,
              record.status == .posted || record.status == .hold, account.extraCurrencies.contains(record.currency) else { return false }
        let balances = try LedgerBackend.balanceSummaries(db, account: account, charges: ChargeCalculator(db: db, calendar: calendar))
        guard let available = balances.first(where: { $0.currency == record.currency })?.availableMinor else { return false }
        return available < record.amountMinor
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

    /// 银行发来的通知（不是手动记的，也不是截图）
    static let messageSources: Set<SourceKind> = [.sms, .email, .notification, .auto, .other]

    /// 同一笔交易的两条通知，一条写全了（交易时间到分钟，常常还有商户和预授权时间，招行 95555 短信）、
    /// 一条只有卡号和金额（招行 App 推送「扣款人民币 126.84」）：同账户、同金额币种方向和状态，系统时间 20 分钟内，
    /// 正好一边没写交易时间、另一边写到了分钟，都是银行的通知。
    /// 已有的那笔只能有一条来源：已经合过一次的不再合，同一张卡连着两笔一样的金额时不会把第二笔并进第一笔。
    /// 只有一笔对得上才算；几笔都像时照常交给用户判断（`possibleDuplicate`）
    func detailTwin(of record: LedgerRecord) throws -> LedgerRecord? {
        guard Self.messageSources.contains(record.source) else { return nil }
        let full = record.transactionTime?.isMinutePrecise == true
        guard full || record.transactionTime == nil else { return nil }
        let window: TimeInterval = 20 * 60
        let matches = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        ).filter { other in
            guard other.accountID == record.accountID, other.status == record.status, Self.messageSources.contains(other.source) else { return false }
            return full ? other.transactionTime == nil : other.transactionTime?.isMinutePrecise == true
        }
        guard matches.count == 1, try RecordDAO.evidence(db, recordID: matches[0].id).count == 1 else { return nil }
        return matches[0]
    }

    /// 把写全的那条补到只有卡号和金额的那笔上：交易时间、商户、交易性质（推送认不出时）；去重键换成按时间算的，
    /// 之后同一条短信（或邮件）再来按去重键合并。补上商户后没分类的重新归类；短信写了预授权时间就了结那笔冻结
    func mergeDetail(_ record: LedgerRecord, into twin: LedgerRecord, dedupeKey key: String, holdTime: WallClock?, meta: IngestMeta) throws -> CommitOutcome {
        var updated = twin
        if twin.transactionTime == nil, let time = record.transactionTime {
            updated.transactionTime = time
            if updated.receivedAt == nil { updated.receivedAt = record.receivedAt }
            try RecordDAO.setDedupeKey(db, id: twin.id, key: key)
        }
        if updated.counterparty == nil, let name = record.counterparty { updated.counterparty = name }
        if updated.kind == .other, record.kind != .other { updated.kind = record.kind }
        if updated != twin { _ = try RecordDAO.update(db, updated) }
        try RecordDAO.addEvidence(db, recordID: twin.id, ingestID: meta.ingestID, source: meta.source, at: now)
        try AccountDAO.noteSuccess(db, id: twin.accountID, at: now, source: meta.source)
        if updated.counterparty != twin.counterparty, updated.categoryID == nil { try Categorizer(db: db).categorize(recordID: twin.id) }
        try closeHold(of: updated, holdTime: holdTime)
        return .merged(twin.id)
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

    /// 页面或通知上写的交易时间（年月日时分都有）换成这台手机的时间
    func date(of clock: WallClock?) -> Date? {
        guard let clock, let year = clock.year, let month = clock.month, let day = clock.day, let hour = clock.hour, let minute = clock.minute else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: clock.second ?? 0))
    }

    // MARK: 截图（ADR 0021）

    struct ScreenshotRoute {
        /// 定下来的账户；nil 时按卡号尾号、钱包照常匹配
        var account: Account?
        /// 账户是猜的：页面没写用什么付的
        var assumed: Bool
        var pending: PendingReason?
        var candidates: [String]
    }

    /// 截图记到哪：写了卡的照常按尾号和银行找卡；零钱通、余额宝、花呗、经营账户先找名称里有它的账户；
    /// 其余记到这个 App 的钱包。认不出是哪个 App 时，用户只有一个微信或支付宝钱包就是它
    func screenshotRoute(_ draft: EventDraft, reading: ScreenshotReading, accounts: [Account]) -> ScreenshotRoute {
        if draft.cardTail != nil || draft.bankHint != nil { return ScreenshotRoute(account: nil, assumed: false, pending: nil, candidates: []) }
        let assumed = !reading.methodStated
        let active = accounts.filter { !$0.archived }
        if let name = reading.methodName {
            let named = active.filter { $0.name.contains(name) }
            if named.count == 1 { return ScreenshotRoute(account: named[0], assumed: false, pending: nil, candidates: []) }
            if named.count > 1 { return ScreenshotRoute(account: nil, assumed: false, pending: .ambiguousAccount, candidates: named.map(\.id)) }
            // 花呗是借的钱、亲属卡是别人的钱：不能记到余额里
            if name == "花呗" || name == "亲属卡" { return ScreenshotRoute(account: nil, assumed: false, pending: .noWalletAccount, candidates: []) }
        }
        let providers = draft.walletHint.map { [$0] } ?? ["wechatpay", "alipay"]
        var wallets = active.filter { account in WalletDirectory.provider(of: account).map(providers.contains) ?? false }
        // 付的是零钱、余额（或者经营账户没有单独的账户）：同一个 App 还有零钱通、余额宝账户时不算它们
        if wallets.count > 1, reading.methodName == nil || reading.methodName == "经营账户" {
            let plain = wallets.filter { wallet in !["零钱通", "余额宝", "花呗"].contains { wallet.name.contains($0) } }
            if !plain.isEmpty { wallets = plain }
        }
        switch wallets.count {
        case 0: return ScreenshotRoute(account: nil, assumed: assumed, pending: .noWalletAccount, candidates: [])
        case 1: return ScreenshotRoute(account: wallets[0], assumed: assumed, pending: nil, candidates: [])
        default: return ScreenshotRoute(account: nil, assumed: assumed, pending: .ambiguousAccount, candidates: wallets.map(\.id))
        }
    }

    /// 银行 App 的换汇页记到哪：页面上没有银行名称和卡号，记到同时有这两个币种的账户（信用卡不算）。
    /// 只有一个就是它；几个都有、或者一个都没有（账户还没加这个币种）时让用户选，候选是有其中一个币种的账户
    static func exchangeRoute(_ drafts: [EventDraft], accounts: [Account]) -> ScreenshotRoute {
        let codes = Set(drafts.compactMap(\.amount.preferredCurrency))
        let usable = accounts.filter { !$0.archived && $0.cardType != .credit }
        let both = usable.filter { codes.isSubset(of: Set($0.currencies)) }
        if both.count == 1 { return ScreenshotRoute(account: both[0], assumed: false, pending: nil, candidates: []) }
        let either = usable.filter { !codes.isDisjoint(with: $0.currencies) }
        let candidates = both.isEmpty ? (either.isEmpty ? usable : either) : both
        return ScreenshotRoute(account: nil, assumed: false, pending: .ambiguousAccount, candidates: candidates.map(\.id))
    }

    /// 换汇的卖出、买入两笔配成一对（和手动记的同卡换汇一样）。已经是一对的不动；有一笔失败的不配
    func pairExchange(_ ids: [String]) throws {
        let records = try ids.compactMap { try RecordDAO.find(db, id: $0) }
        guard records.count == 2, records.allSatisfy({ $0.status == .posted }) else { return }
        if let group = records[0].transferGroupID, records[1].transferGroupID == group { return }
        try RecordDAO.setTransferGroup(db, ids: ids, group: newID())
    }

    /// 截图和银行通知（或者同一笔的另一张截图）是不是同一笔：金额、币种、方向、状态一样，时间对得上，在同一个账户；
    /// 或者一边是没写用什么付的截图（记到了猜的钱包），另一边是卡。只有一笔对得上才算；几笔都像时照常处理。
    /// 手动记的不在这里合并，照常问是不是同一笔
    func screenshotTwin(of record: LedgerRecord, accounts: [Account], assumedAccount: Bool) throws -> LedgerRecord? {
        let window: TimeInterval = 10 * 60
        let candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        ).filter { $0.status == record.status && $0.source != .manual && ($0.source == .screenshot || record.source == .screenshot) }
        guard !candidates.isEmpty else { return nil }
        func kindOf(_ id: String) -> CardType? { accounts.first { $0.id == id }?.cardType }
        let matches = try candidates.filter { other in
            if other.accountID != record.accountID {
                if record.source == .screenshot {
                    guard assumedAccount, kindOf(record.accountID) == .wallet, kindOf(other.accountID)?.isCard == true else { return false }
                } else {
                    guard kindOf(record.accountID)?.isCard == true, kindOf(other.accountID) == .wallet, try screenshotAssumed(other) else { return false }
                }
            }
            // 两张截图都写了单号又不一样：是两笔
            if record.source == other.source, let a = record.bankReference, let b = other.bankReference, a != b { return false }
            if let a = date(of: record.transactionTime), let b = date(of: other.transactionTime) { return abs(a.timeIntervalSince(b)) <= 3 * 60 }
            // 两张截图都没写时间（付款成功页）：截图的时间要很近
            if record.source == other.source { return abs(record.effectiveAt.timeIntervalSince(other.effectiveAt)) <= 3 * 60 }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 以前那笔截图的钱包是不是猜的：看它的截图原文写没写用什么付的。有一张写明了就不是；原文已经清掉的不算猜的
    func screenshotAssumed(_ record: LedgerRecord) throws -> Bool {
        guard record.source == .screenshot else { return false }
        var unstated = false
        for shot in try RecordDAO.evidence(db, recordID: record.id) where shot.source == .screenshot {
            guard let raw = shot.rawText else { continue }
            if ScreenshotParser.statesMethod(raw, calendar: calendar) { return false }
            unstated = true
        }
        return unstated
    }

    private static let paymentChannel = Rx(#"财付通|微信|支付宝|tenpay|alipay|银联|快捷支付|网上支付|扫码|二维码"#)

    /// 合并成一笔，加一份来源证据。
    /// 截图来了：银行没写商户、或者写的是「财付通-…」这类渠道时，用截图上的商户；原来那张截图的钱包是猜的、这张写明了，改到写明的账户；
    /// 原来没有页面上的时间就补上。银行通知来了、截图那笔的钱包是猜的：改到这张卡上
    func mergeScreenshot(_ record: LedgerRecord, into twin: LedgerRecord, meta: IngestMeta, assumedAccount: Bool) throws -> CommitOutcome {
        var updated = twin
        if record.source == .screenshot {
            if let name = record.counterparty, twin.counterparty == nil || (twin.source != .screenshot && Self.paymentChannel.test(twin.counterparty ?? "")) {
                updated.counterparty = name
            }
            if twin.source == .screenshot, twin.accountID != record.accountID, !assumedAccount, try screenshotAssumed(twin) {
                updated.accountID = record.accountID
            }
            if twin.transactionTime?.isMinutePrecise != true, record.transactionTime?.isMinutePrecise == true {
                updated.transactionTime = record.transactionTime
                updated.receivedAt = record.receivedAt
            }
        } else if twin.accountID != record.accountID {
            updated.accountID = record.accountID
        }
        if updated != twin { try RecordDAO.update(db, updated) }
        try RecordDAO.addEvidence(db, recordID: twin.id, ingestID: meta.ingestID, source: meta.source, at: now)
        try AccountDAO.noteSuccess(db, id: updated.accountID, at: now, source: meta.source)
        if updated.counterparty != twin.counterparty, updated.categoryID == nil { try Categorizer(db: db).categorize(recordID: twin.id) }
        return .merged(twin.id)
    }
}
