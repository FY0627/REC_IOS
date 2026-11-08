import Foundation

/// 快捷指令交给 App 的一次输入。只包含系统实际提供的字段，缺失就是 nil。
public struct IngestRequest: Sendable, Hashable {
    public var text: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    public var receivedAt: Date?
    public var messageID: String?
    public var boundAccountID: String?

    public init(text: String, source: SourceKind, sender: String? = nil, subject: String? = nil, receivedAt: Date? = nil, messageID: String? = nil, boundAccountID: String? = nil) {
        self.text = text
        self.source = source
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.boundAccountID = boundAccountID
    }
}

/// 整条通知的类别。
public enum MessageClassification: String, Sendable, Codable, CaseIterable {
    case transaction
    case verificationCode
    case marketing
    case reminder
    case statement
    case balanceSnapshot
    case creditLimitChange
    /// 不是动账通知（普通短信、运营商或快递通知等）：对不上自己的账户，也看不出是银行或电子钱包发的。不保存
    case noFinancialContent
    case unrecognized
    case empty

    public var displayName: String {
        switch self {
        case .transaction: "资金变动"
        case .verificationCode: "验证码（内容未保存）"
        case .marketing: "营销信息"
        case .reminder: "还款/账单/扣款提醒"
        case .statement: "账单/对账单（不重复入账）"
        case .balanceSnapshot: "余额通知（无交易）"
        case .creditLimitChange: "额度或限额变化"
        case .noFinancialContent: "不是动账通知（对不上自己的账户，也看不出是银行发的）"
        case .unrecognized: "未能识别"
        case .empty: "空输入（快捷指令未传入内容）"
        }
    }
}

/// 一次输入的最终处理结果。
public enum IngestOutcome: String, Sendable, Codable {
    /// 至少一笔已入账，没有待处理
    case recorded
    /// 有内容进入待处理（可能同时有已入账的）
    case pending
    /// 识别为非交易信息，只记日志
    case filtered
    /// 与之前的输入完全相同
    case duplicateInput
    /// 每一笔都与已有流水重复，已合并为来源证据
    case mergedDuplicate
}

public struct IngestResult: Sendable, Hashable {
    public var ingestID: String?
    public var outcome: IngestOutcome
    public var classification: MessageClassification
    public var recordedCount: Int
    public var mergedCount: Int
    public var pendingCount: Int
    public var summary: String
    /// 每一笔交易的处理结果（用于记账结果通知），顺序与通知里的交易一致
    public var items: [IngestItem]

    public init(ingestID: String?, outcome: IngestOutcome, classification: MessageClassification, recordedCount: Int, mergedCount: Int, pendingCount: Int, summary: String, items: [IngestItem] = []) {
        self.ingestID = ingestID
        self.outcome = outcome
        self.classification = classification
        self.recordedCount = recordedCount
        self.mergedCount = mergedCount
        self.pendingCount = pendingCount
        self.summary = summary
        self.items = items
    }
}

/// 一笔交易的处理结果：哪张卡、什么动作、多少钱、是否入账。
public struct IngestItem: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        /// 新入账
        case recorded
        /// 与已有流水是同一笔（另一来源），只合并为来源证据
        case merged
        /// 没能自动入账，进入待处理
        case pending(PendingReason)
    }

    /// 入账时是账户的尾号；待处理时是通知里写的尾号（可能没有）
    public var cardTail: String?
    public var kind: TransactionKind?
    public var status: SettlementStatus?
    /// 入账时是确定的金额和币种
    public var amountMinor: Int64?
    public var currency: CurrencyCode?
    /// 待处理时是通知里的金额原文，例如 `1,234.56`
    public var amountText: String?
    public var result: Result
    /// 入账或合并到的流水；待处理时是 nil
    public var recordID: String?
    /// 新入账的支出换成账户的另一个币种扣：扣了多少（多半是按汇率估算的）
    public var charge: RecordCharge?
    /// 换币种是因为这个币种的余额不够（多币种账户），不是账户没有这个币种
    public var insufficientBalance: Bool
    /// 记到的不是卡（现金、电子钱包）：账户名称，通知里不写尾号
    public var accountTitle: String?
    /// 交易对方或商户（截图记账的通知写出来，看得出是哪一笔）
    public var counterparty: String?

    public init(
        cardTail: String?, kind: TransactionKind?, status: SettlementStatus?, amountMinor: Int64?, currency: CurrencyCode?, amountText: String?,
        result: Result, recordID: String? = nil, charge: RecordCharge? = nil, insufficientBalance: Bool = false,
        accountTitle: String? = nil, counterparty: String? = nil
    ) {
        self.cardTail = cardTail
        self.kind = kind
        self.status = status
        self.amountMinor = amountMinor
        self.currency = currency
        self.amountText = amountText
        self.result = result
        self.recordID = recordID
        self.charge = charge
        self.insufficientBalance = insufficientBalance
        self.accountTitle = accountTitle
        self.counterparty = counterparty
    }
}

/// 接收日志：每条输入怎么处理的（界面上不显示，排查用）。
public struct IngestLogEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    public var receivedAt: Date?
    public var processedAt: Date
    public var classification: MessageClassification
    public var outcome: IngestOutcome
    public var detail: String
    public var rawText: String?
    public var boundAccountID: String?

    public init(id: String, source: SourceKind, sender: String?, subject: String?, receivedAt: Date?, processedAt: Date, classification: MessageClassification, outcome: IngestOutcome, detail: String, rawText: String?, boundAccountID: String?) {
        self.id = id
        self.source = source
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.classification = classification
        self.outcome = outcome
        self.detail = detail
        self.rawText = rawText
        self.boundAccountID = boundAccountID
    }
}

public enum PendingReason: String, Sendable, Codable, CaseIterable {
    /// 同尾号多个账户或来源冲突
    case ambiguousAccount
    /// 没有与尾号匹配的账户
    case noMatchingAccount
    /// 正文里没有尾号，只有快捷指令绑定的账户可作为候选
    case missingCardTail
    /// 正文里找不到金额
    case missingAmount
    /// 同一句里有多个可能是交易金额的数字，或金额格式有歧义
    case ambiguousAmount
    /// 币种无法确定
    case unknownCurrency
    /// 无法判断资金方向或交易性质
    case uncertainKind
    /// 与另一来源的已有流水高度相似但证据不足以合并
    case possibleDuplicate
    /// 整条通知未能识别
    case unrecognized
    /// 支付宝、微信支付的余额收支，还没有添加这个电子钱包。添加后自动入账
    case noWalletAccount

    public var displayName: String {
        switch self {
        case .ambiguousAccount: "多个账户都可能匹配"
        case .noMatchingAccount: "没有与尾号匹配的账户"
        case .missingCardTail: "通知里没有卡号尾号"
        case .missingAmount: "没有找到交易金额"
        case .ambiguousAmount: "金额有歧义"
        case .unknownCurrency: "无法确定币种"
        case .uncertainKind: "无法确定资金方向"
        case .possibleDuplicate: "可能与已有流水重复"
        case .unrecognized: "暂不支持的通知格式"
        case .noWalletAccount: "没有添加这个电子钱包"
        }
    }

    /// 是否允许用户从系统给出的候选中确认入账。
    /// 金额有歧义时，同一条通知里认出的每个数字各是一个候选，用户确认其中一个，其余的自动忽略。
    public var allowsConfirmation: Bool {
        switch self {
        case .ambiguousAccount, .missingCardTail, .possibleDuplicate, .noMatchingAccount, .ambiguousAmount, .noWalletAccount: true
        default: false
        }
    }
}

public enum PendingStatus: String, Sendable, Codable {
    case open
    case confirmed
    case ignored
}

/// 通知里的一个金额：先保留原文，等币种确定后再按该币种的小数位换算成最小单位。
public struct AmountText: Hashable, Sendable, Codable {
    /// 去掉货币符号后的数字原文，例如 `1,234.56`、`1.234,56`
    public var digits: String
    /// 在这个金额旁边写明的币种候选（`¥` 可能是 CNY 或 JPY，`$` 可能是多种美元）
    public var currencyCandidates: [CurrencyCode]
    /// 候选有多个时，按书写习惯优先考虑的一个（例如中文短信里的「元」「¥」→ CNY）
    public var preferredCurrency: CurrencyCode?

    public init(digits: String, currencyCandidates: [CurrencyCode], preferredCurrency: CurrencyCode?) {
        self.digits = digits
        self.currencyCandidates = currencyCandidates
        self.preferredCurrency = preferredCurrency
    }
}

/// 解析出的一笔交易草稿，账户可能尚未确定。
public struct EventDraft: Hashable, Sendable, Codable {
    public var amount: AmountText
    public var direction: FlowDirection?
    public var kind: TransactionKind
    public var status: SettlementStatus
    public var counterparty: String?
    public var cardTail: String?
    public var counterpartyTail: String?
    public var transactionTime: WallClock?
    public var bankReference: String?
    public var balanceAfter: AmountText?
    /// 原交易金额里「含手续费」的部分；已拆成单独的手续费草稿
    public var includedFee: AmountText?
    /// 由「含手续费」拆出来的手续费部分
    public var isSplitFee: Bool
    public var partIndex: Int
    public var bankHint: String?
    /// 发通知的电子钱包（`WalletDirectory`），只在认不出银行时才有
    public var walletHint: String?
    /// 通知写在括号里的实际扣款（「JPY1000.00（人民币48.00）」的人民币 48.00）。
    /// 待处理草稿存成 JSON，这个字段之前没有，旧草稿读出来是 nil
    public var settlement: AmountText?
    /// 通知写明的之前那笔预授权的时间（「完成扣款…（交易预授权时间10月30日10:20）」）。同样可以缺失
    public var holdTime: WallClock?
    /// 原文中这笔交易所在的句子（展示给用户核对，不会上传）
    public var evidenceSnippet: String

    public init(amount: AmountText, direction: FlowDirection?, kind: TransactionKind, status: SettlementStatus, counterparty: String?, cardTail: String?, counterpartyTail: String?, transactionTime: WallClock?, bankReference: String?, balanceAfter: AmountText?, includedFee: AmountText?, isSplitFee: Bool, partIndex: Int, bankHint: String?, walletHint: String? = nil, settlement: AmountText? = nil, holdTime: WallClock? = nil, evidenceSnippet: String) {
        self.amount = amount
        self.direction = direction
        self.kind = kind
        self.status = status
        self.counterparty = counterparty
        self.cardTail = cardTail
        self.counterpartyTail = counterpartyTail
        self.transactionTime = transactionTime
        self.bankReference = bankReference
        self.balanceAfter = balanceAfter
        self.includedFee = includedFee
        self.isSplitFee = isSplitFee
        self.partIndex = partIndex
        self.bankHint = bankHint
        self.walletHint = walletHint
        self.settlement = settlement
        self.holdTime = holdTime
        self.evidenceSnippet = evidenceSnippet
    }
}

public struct PendingItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var ingestID: String
    public var reason: PendingReason
    public var draft: EventDraft?
    public var candidateAccountIDs: [String]
    public var duplicateOfRecordID: String?
    public var status: PendingStatus
    public var createdAt: Date
    public var source: SourceKind
    public var sender: String?
    public var receivedAt: Date?
    public var rawText: String?

    public init(id: String, ingestID: String, reason: PendingReason, draft: EventDraft?, candidateAccountIDs: [String], duplicateOfRecordID: String?, status: PendingStatus, createdAt: Date, source: SourceKind, sender: String?, receivedAt: Date?, rawText: String?) {
        self.id = id
        self.ingestID = ingestID
        self.reason = reason
        self.draft = draft
        self.candidateAccountIDs = candidateAccountIDs
        self.duplicateOfRecordID = duplicateOfRecordID
        self.status = status
        self.createdAt = createdAt
        self.source = source
        self.sender = sender
        self.receivedAt = receivedAt
        self.rawText = rawText
    }
}

/// 银行通知里写明的余额（快照）。
public struct BalanceObservation: Hashable, Sendable {
    public var accountID: String
    public var amountMinor: Int64
    public var currency: CurrencyCode
    /// 用于判断新旧：有正文时间就用正文时间，否则用系统接收时间/处理时间。
    public var orderKey: String
    public var transactionTime: WallClock?
    public var observedAt: Date
    public var recordID: String?

    public init(accountID: String, amountMinor: Int64, currency: CurrencyCode, orderKey: String, transactionTime: WallClock?, observedAt: Date, recordID: String?) {
        self.accountID = accountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.orderKey = orderKey
        self.transactionTime = transactionTime
        self.observedAt = observedAt
        self.recordID = recordID
    }
}

/// 一张卡全部币种的余额，顺序与账户币种一致（主币种在前）。
public struct AccountBalances: Hashable, Sendable {
    public var accountID: String
    public var items: [AccountBalanceSummary]

    public init(accountID: String, items: [AccountBalanceSummary]) {
        self.accountID = accountID
        self.items = items
    }

    /// 主币种
    public var primary: AccountBalanceSummary? { items.first }
    /// 卡面上显示的币种：主币种有余额就用主币种，否则用第一个有余额的币种
    public var display: AccountBalanceSummary? { items.first { $0.ledgerDerivedMinor != nil } ?? items.first }

    public func item(_ currency: CurrencyCode) -> AccountBalanceSummary? {
        items.first { $0.currency == currency }
    }
}

/// 某张卡某个币种的余额：从用户填写的初始余额出发，加上之后从这个币种扣款（入账）的已入账流水，
/// 包括别的币种换成它扣的（账户没有的币种按主币种，多币种账户余额不够时换主币种，`RecordCharge`）。
/// 银行通知里写的余额不使用（很多银行不提供，写法也不统一）。
public struct AccountBalanceSummary: Hashable, Sendable {
    public var accountID: String
    public var currency: CurrencyCode
    /// 用户填写的初始余额及其时间点
    public var openingBalanceMinor: Int64?
    public var openingBalanceAt: Date?
    /// 初始余额 + 之后已入账的流水；没有初始余额时为 nil（未知）
    public var ledgerDerivedMinor: Int64?
    /// 推算用到的、晚于初始余额的流水笔数
    public var recordsAfterBase: Int
    /// 换成这个币种扣的交易里，还没有任何汇率、算不出扣款而没有计入的笔数
    public var unconvertedCount: Int
    /// 晚于初始余额、还没结清的冻结（预授权）合计：不计入余额，但这部分钱已经不能用
    public var openHoldsMinor: Int64

    public init(
        accountID: String,
        currency: CurrencyCode,
        ledgerDerivedMinor: Int64?,
        recordsAfterBase: Int,
        openingBalanceMinor: Int64? = nil,
        openingBalanceAt: Date? = nil,
        unconvertedCount: Int = 0,
        openHoldsMinor: Int64 = 0
    ) {
        self.accountID = accountID
        self.currency = currency
        self.ledgerDerivedMinor = ledgerDerivedMinor
        self.recordsAfterBase = recordsAfterBase
        self.openingBalanceMinor = openingBalanceMinor
        self.openingBalanceAt = openingBalanceAt
        self.unconvertedCount = unconvertedCount
        self.openHoldsMinor = openHoldsMinor
    }

    /// 可用余额：推算余额减去还没结清的冻结；余额未知时为 nil
    public var availableMinor: Int64? { ledgerDerivedMinor.map { $0 - openHoldsMinor } }
}

/// 某账户的自动记账可观测状态。App 读不到快捷指令自动化是否启用，只能展示实际接收情况。
public struct AccountAutomationStatus: Hashable, Sendable {
    public var accountID: String
    public var lastSuccessAt: Date?
    public var lastSuccessSource: SourceKind?
    public var receivedCount: Int

    public init(accountID: String, lastSuccessAt: Date?, lastSuccessSource: SourceKind?, receivedCount: Int) {
        self.accountID = accountID
        self.lastSuccessAt = lastSuccessAt
        self.lastSuccessSource = lastSuccessSource
        self.receivedCount = receivedCount
    }
}

/// 统计页的月度汇总（按币种分开，不做汇率换算）。
public struct MonthStats: Hashable, Sendable {
    public struct CurrencyTotals: Hashable, Sendable {
        public var currency: CurrencyCode
        /// 支出：流出，不含转帐（内部转账、还款、存取现金）
        public var expenseMinor: Int64
        /// 收入：流入，不含转帐、退款、冲正
        public var incomeMinor: Int64
        /// 退款与流入方向的冲正
        public var refundMinor: Int64
        /// 内部转账（两边都在账本里或已明确关联），不计入收支
        public var internalTransferMinor: Int64
        /// 还款，不计入收支
        public var repaymentMinor: Int64
        public var recordCount: Int
        public var byKind: [KindTotal]
        /// 转帐合计（自己的账户之间互转、还信用卡、存取现金），不计入收支；配对的两边只算转出那边
        public var transferMinor: Int64
        /// 支出按分类：大类按金额从大到小，退款从它所在的分类里减掉；没分类的在「待分类」
        public var expenseCategories: [CategoryTotal]
        /// 收入按分类
        public var incomeCategories: [CategoryTotal]

        public init(
            currency: CurrencyCode, expenseMinor: Int64, incomeMinor: Int64, refundMinor: Int64, internalTransferMinor: Int64, repaymentMinor: Int64,
            recordCount: Int, byKind: [KindTotal], transferMinor: Int64 = 0, expenseCategories: [CategoryTotal] = [], incomeCategories: [CategoryTotal] = []
        ) {
            self.currency = currency
            self.expenseMinor = expenseMinor
            self.incomeMinor = incomeMinor
            self.refundMinor = refundMinor
            self.internalTransferMinor = internalTransferMinor
            self.repaymentMinor = repaymentMinor
            self.recordCount = recordCount
            self.byKind = byKind
            self.transferMinor = transferMinor
            self.expenseCategories = expenseCategories
            self.incomeCategories = incomeCategories
        }

        /// 支出减去退款
        public var netExpenseMinor: Int64 { expenseMinor - refundMinor }
        /// 收入减去支出
        public var balanceMinor: Int64 { incomeMinor - netExpenseMinor }
    }

    /// 一个分类的合计。大类的 `children` 是它的小类；直接记在大类上的那部分也作为一项，名称和大类相同
    public struct CategoryTotal: Hashable, Sendable, Identifiable {
        /// nil 是「待分类」
        public var categoryID: String?
        public var name: String
        public var symbol: String
        public var amountMinor: Int64
        public var count: Int
        public var children: [CategoryTotal]

        public init(categoryID: String?, name: String, symbol: String, amountMinor: Int64, count: Int, children: [CategoryTotal] = []) {
            self.categoryID = categoryID
            self.name = name
            self.symbol = symbol
            self.amountMinor = amountMinor
            self.count = count
            self.children = children
        }

        public var id: String { categoryID ?? "uncategorized" }
    }

    public struct KindTotal: Hashable, Sendable {
        public var kind: TransactionKind
        public var direction: FlowDirection
        public var amountMinor: Int64
        public var count: Int

        public init(kind: TransactionKind, direction: FlowDirection, amountMinor: Int64, count: Int) {
            self.kind = kind
            self.direction = direction
            self.amountMinor = amountMinor
            self.count = count
        }
    }

    public struct AccountTotal: Hashable, Sendable {
        public var accountID: String
        public var currency: CurrencyCode
        public var inflowMinor: Int64
        public var outflowMinor: Int64
        public var count: Int

        public init(accountID: String, currency: CurrencyCode, inflowMinor: Int64, outflowMinor: Int64, count: Int) {
            self.accountID = accountID
            self.currency = currency
            self.inflowMinor = inflowMinor
            self.outflowMinor = outflowMinor
            self.count = count
        }
    }

    /// 所有币种换算成一个币种（首页的本月支出、收入、结余）。
    /// 外币交易有实际扣款的用实际扣款，否则按交易当天的汇率换算；没有汇率的不计入，币种列在 `unconverted`
    public struct ConvertedTotals: Hashable, Sendable {
        public var currency: CurrencyCode
        /// 支出减去退款
        public var expenseMinor: Int64
        public var incomeMinor: Int64
        public var unconverted: [CurrencyCode]
        /// 支出按分类（换算后的金额），排法和 `CurrencyTotals.expenseCategories` 一样
        public var expenseCategories: [CategoryTotal]
        /// 收入按分类（换算后的金额）
        public var incomeCategories: [CategoryTotal]

        public init(
            currency: CurrencyCode, expenseMinor: Int64, incomeMinor: Int64, unconverted: [CurrencyCode],
            expenseCategories: [CategoryTotal] = [], incomeCategories: [CategoryTotal] = []
        ) {
            self.currency = currency
            self.expenseMinor = expenseMinor
            self.incomeMinor = incomeMinor
            self.unconverted = unconverted
            self.expenseCategories = expenseCategories
            self.incomeCategories = incomeCategories
        }

        public var balanceMinor: Int64 { incomeMinor - expenseMinor }
    }

    public var year: Int
    public var month: Int
    public var currencies: [CurrencyTotals]
    public var accounts: [AccountTotal]
    public var holdCount: Int
    public var failedCount: Int
    /// 按要求换算成一个币种的合计；没要求时为 nil
    public var converted: ConvertedTotals?

    public init(year: Int, month: Int, currencies: [CurrencyTotals], accounts: [AccountTotal], holdCount: Int, failedCount: Int, converted: ConvertedTotals? = nil) {
        self.year = year
        self.month = month
        self.currencies = currencies
        self.accounts = accounts
        self.holdCount = holdCount
        self.failedCount = failedCount
        self.converted = converted
    }
}
