import Foundation

/// 资金方向，相对于账户本身：钱进入账户为流入，离开账户为流出。
/// 信用卡消费是流出（负债增加），信用卡还款是流入。
public enum FlowDirection: String, Sendable, Codable, CaseIterable {
    case inflow
    case outflow

    public var opposite: FlowDirection { self == .inflow ? .outflow : .inflow }
    public var displayName: String { self == .inflow ? "流入" : "流出" }
}

/// 交易性质。不是用户分类：用户不能管理它，它只用来正确处理退款、转账、还款等。
public enum TransactionKind: String, Sendable, Codable, CaseIterable {
    case purchase
    case income
    case salary
    case transferIn
    case transferOut
    case refund
    case repayment
    case interestCharge
    case fee
    case deposit
    case withdrawal
    case interestIncome
    case reversal
    case other

    public var displayName: String {
        switch self {
        case .purchase: "消费"
        case .income: "入账"
        case .salary: "工资"
        case .transferIn: "转入"
        case .transferOut: "转出"
        case .refund: "退款"
        case .repayment: "还款"
        case .interestCharge: "扣息"
        case .fee: "手续费"
        case .deposit: "存入"
        case .withdrawal: "取款"
        case .interestIncome: "利息"
        case .reversal: "冲正/撤销"
        case .other: "其他"
        }
    }

    /// 可以与另一账户的反向流水配对成内部转账的性质。
    public var isTransferLike: Bool {
        switch self {
        case .transferIn, .transferOut, .repayment, .deposit, .withdrawal: true
        default: false
        }
    }
}

/// 结算状态：只有 `posted` 计入收支和余额推算。
public enum SettlementStatus: String, Sendable, Codable, CaseIterable {
    /// 已发生的资金变动
    case posted
    /// 预授权、冻结：资金被占用但未结算
    case hold
    /// 预授权撤销、解冻
    case holdReleased
    /// 支付失败、交易未成功
    case failed

    public var displayName: String {
        switch self {
        case .posted: "已入账"
        case .hold: "冻结/预授权"
        case .holdReleased: "解冻/撤销预授权"
        case .failed: "交易失败"
        }
    }
}

public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case sms
    case email
    /// 银行 App 的推送通知
    case notification
    case other
    /// 一个自动化同时接收短信、邮件、App 通知，分不出是哪一种
    case auto
    /// 用户在 App 里手动记的一笔（没有通知）
    case manual

    public var displayName: String {
        switch self {
        case .sms: "短信"
        case .email: "邮件"
        case .notification: "App 通知"
        case .other: "其他文本"
        case .auto: "自动化"
        case .manual: "手动记账"
        }
    }
}

/// 用户看到的记账类型（参考 MOZE 的基础记账）：支出、收入、转帐。
/// 由交易性质、方向和转账关联推出来，不单独保存；14 种交易性质只留在后台给识别和对账用。
public enum EntryType: String, Sendable, Codable, CaseIterable {
    case expense
    case income
    /// 钱在自己的账户之间挪动：自己的卡互转、还信用卡、存取现金。不算收支
    case transfer

    public var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转帐"
        }
    }
}

/// 通知正文里写明的交易时间（银行所在地的墙上时间，不做时区换算）。
public struct WallClock: Hashable, Sendable, Codable, Comparable {
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    public var second: Int?
    /// 年份是根据接收时间推断的（正文只写了月日）。
    public var yearInferred: Bool

    public init(year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, second: Int? = nil, yearInferred: Bool = false) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.yearInferred = yearInferred
    }

    public var hasDate: Bool { month != nil && day != nil }
    public var hasTime: Bool { hour != nil && minute != nil }
    /// 精确到分钟，可以作为强去重证据。
    public var isMinutePrecise: Bool { year != nil && hasDate && hasTime }

    private static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }

    /// 可排序的文本，例如 `2026-10-24T14:30`；缺失部分省略。
    public var sortKey: String {
        var text = ""
        if let year { text += Self.pad(year, 4) } else { text += "????" }
        if let month, let day { text += "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2) }
        if let hour, let minute {
            text += "T" + Self.pad(hour, 2) + ":" + Self.pad(minute, 2)
            if let second { text += ":" + Self.pad(second, 2) }
        }
        return text
    }

    public var displayText: String {
        var parts: [String] = []
        if let month, let day {
            if let year, !yearInferred { parts.append("\(year)年\(month)月\(day)日") } else { parts.append("\(month)月\(day)日") }
        }
        if let hour, let minute { parts.append(Self.pad(hour, 2) + ":" + Self.pad(minute, 2)) }
        return parts.joined(separator: " ")
    }

    public static func < (lhs: WallClock, rhs: WallClock) -> Bool { lhs.sortKey < rhs.sortKey }
}

/// 没有配对到自己另一张卡的转账，由用户确认对方是不是自己的账户。
public enum TransferParty: String, Sendable, Codable, CaseIterable {
    /// 自己在别处的账户（没有添加到 App 的卡、电子钱包等）：算内部转账，不计入收支
    case own
    /// 别人：转出算支出，转入算收入
    case other
}

/// 一条资金变动记录。用户可以改金额、币种、方向、性质、账户、交易对方、时间、备注、转账去向和实际扣款，也可以删除；
/// 来源、通知原文和结算状态不能改。
public struct LedgerRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var accountID: String
    public var amountMinor: Int64
    public var currency: CurrencyCode
    public var direction: FlowDirection
    public var kind: TransactionKind
    public var status: SettlementStatus
    public var counterparty: String?
    public var transactionTime: WallClock?
    /// 系统提供的接收时间；系统没提供就是 nil，不用处理时间冒充。
    public var receivedAt: Date?
    /// App 处理这条输入的时间。
    public var processedAt: Date
    public var source: SourceKind
    public var ingestID: String
    public var partIndex: Int
    public var bankReference: String?
    public var balanceAfterMinor: Int64?
    /// 本条流水已包含、并已另行拆出的手续费（只用于展示说明）。
    public var includedFeeMinor: Int64?
    public var note: String
    public var transferGroupID: String?
    public var relatedRecordID: String?
    /// 没配对到自己另一张卡的转账，用户确认的对方；nil 表示还没确认（按转给别人统计）
    public var transferParty: TransferParty?
    /// 账户不持有这个币种时，用户填写的实际扣款（账户主币种）；nil 时按交易当天的汇率估算（见 `RecordCharge`）
    public var settlement: Money?
    /// 用户的分类（支出、收入才有）；nil 是「待分类」。转帐的分类按交易性质推出，不保存
    public var categoryID: String?
    /// 一单用了几张卡：同一单的几笔共用这个标识
    public var orderGroupID: String?

    public init(
        id: String, accountID: String, amountMinor: Int64, currency: CurrencyCode, direction: FlowDirection,
        kind: TransactionKind, status: SettlementStatus, counterparty: String?, transactionTime: WallClock?,
        receivedAt: Date?, processedAt: Date, source: SourceKind, ingestID: String, partIndex: Int,
        bankReference: String?, balanceAfterMinor: Int64?, includedFeeMinor: Int64?, note: String,
        transferGroupID: String?, relatedRecordID: String?, transferParty: TransferParty? = nil, settlement: Money? = nil,
        categoryID: String? = nil, orderGroupID: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.direction = direction
        self.kind = kind
        self.status = status
        self.counterparty = counterparty
        self.transactionTime = transactionTime
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.source = source
        self.ingestID = ingestID
        self.partIndex = partIndex
        self.bankReference = bankReference
        self.balanceAfterMinor = balanceAfterMinor
        self.includedFeeMinor = includedFeeMinor
        self.note = note
        self.transferGroupID = transferGroupID
        self.relatedRecordID = relatedRecordID
        self.transferParty = transferParty
        self.settlement = settlement
        self.categoryID = categoryID
        self.orderGroupID = orderGroupID
    }

    /// 排序和按日分组使用的系统时间。
    public var effectiveAt: Date { receivedAt ?? processedAt }
    /// 自己账户之间的转账：两边都是 App 里的卡并已配对，或用户确认对方是自己的账户
    public var isInternalTransfer: Bool { transferGroupID != nil || transferParty == .own }
    /// 转账没有配对到自己另一张卡，也还没确认对方是谁
    public var needsTransferConfirmation: Bool {
        status == .posted && (kind == .transferIn || kind == .transferOut) && transferGroupID == nil && transferParty == nil
    }
    public var money: Money { Money(minorUnits: amountMinor, currency: currency) }

    /// 支出、收入还是转帐。和 `RecordDAO.entryTypeSQL` 的规则一致：
    /// 自己账户之间的转账、还款、存取现金是转帐；流出和退款（冲减支出）是支出；其余流入是收入。
    /// 没确认对方的转账先按转给别人算（转出是支出、转入是收入）
    public var entryType: EntryType {
        if isInternalTransfer || Self.transferKinds.contains(kind) { return .transfer }
        if direction == .outflow || kind == .refund || kind == .reversal { return .expense }
        return .income
    }

    /// 退款、流入的冲正：从支出里减掉，不算收入
    public var isRefund: Bool { entryType == .expense && direction == .inflow }

    /// 不论方向都算转帐的交易性质
    public static let transferKinds: Set<TransactionKind> = [.repayment, .deposit, .withdrawal]
}

/// 显示用的分类：名称、图标，小类还带上大类的名称。
public struct CategoryLabel: Hashable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var parentName: String?

    public init(id: String, name: String, symbol: String, parentName: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.parentName = parentName
    }

    /// 「饮食 · 午餐」；大类只写自己的名称
    public var fullName: String { parentName.map { "\($0) · \(name)" } ?? name }
}

/// 显示用的账户：银行卡写「银行 ·尾号」，现金和电子钱包写名称。
public struct AccountLabel: Hashable, Sendable {
    public var name: String
    public var bankName: String
    public var last4: String
    public var cardType: CardType
    /// 账户已删除（流水还在）
    public var deleted: Bool

    public init(name: String, bankName: String, last4: String, cardType: CardType, deleted: Bool = false) {
        self.name = name
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.deleted = deleted
    }

    public var text: String { (cardType.isCard ? "\(bankName) ·\(last4)" : name) + (deleted ? "（已删除）" : "") }
}

/// 合成一单的其中一笔（首页那一行下面写「招行 700 + 信用卡 300」）
public struct OrderPart: Hashable, Sendable {
    public var recordID: String
    public var account: AccountLabel
    public var amountMinor: Int64
    public var currency: CurrencyCode

    public init(recordID: String, account: AccountLabel, amountMinor: Int64, currency: CurrencyCode) {
        self.recordID = recordID
        self.account = account
        self.amountMinor = amountMinor
        self.currency = currency
    }
}

/// 列表展示用：记录 + 账户摘要。
public struct RecordRow: Identifiable, Hashable, Sendable {
    public var record: LedgerRecord
    public var accountName: String
    public var bankName: String
    public var last4: String
    public var paletteID: String
    /// 账户持有的币种，主币种在前
    public var accountCurrencies: [CurrencyCode]
    /// 账户不持有这笔流水的币种时，按主币种扣款的金额；持有时为 nil
    public var charge: RecordCharge?
    public var cardType: CardType
    /// 这笔流水的账户已删除
    public var accountDeleted: Bool
    /// 分类：支出、收入是用户的分类（nil 为待分类）；转帐按交易性质对应到转帐分类
    public var category: CategoryLabel?
    /// 配对的转帐另一边的账户（首页合成一行「招行 → 工行」）
    public var peer: AccountLabel?
    /// 配对的转帐另一边的金额和币种：有手续费、换汇时和这一笔不一样
    public var peerMoney: Money?
    /// 同一条通知拆出的手续费，合在这一笔下面显示
    public var feeMinor: Int64?
    /// 关联到这一笔的退款合计
    public var refundedMinor: Int64?
    /// 合成一单的几笔（含这一笔），首页只显示一行；不是合单时为空
    public var orderParts: [OrderPart]

    public init(
        record: LedgerRecord, accountName: String, bankName: String, last4: String, paletteID: String,
        accountCurrencies: [CurrencyCode] = [], charge: RecordCharge? = nil, cardType: CardType = .debit, accountDeleted: Bool = false,
        category: CategoryLabel? = nil, peer: AccountLabel? = nil, peerMoney: Money? = nil, feeMinor: Int64? = nil, refundedMinor: Int64? = nil,
        orderParts: [OrderPart] = []
    ) {
        self.record = record
        self.accountName = accountName
        self.bankName = bankName
        self.last4 = last4
        self.paletteID = paletteID
        self.accountCurrencies = accountCurrencies
        self.charge = charge
        self.cardType = cardType
        self.accountDeleted = accountDeleted
        self.category = category
        self.peer = peer
        self.peerMoney = peerMoney
        self.feeMinor = feeMinor
        self.refundedMinor = refundedMinor
        self.orderParts = orderParts
    }

    public var id: String { record.id }
    /// 账户不持有这笔流水的币种（银行按主币种结汇扣款）
    public var isForeignCurrency: Bool { !accountCurrencies.isEmpty && !accountCurrencies.contains(record.currency) }
    public var account: AccountLabel { AccountLabel(name: accountName, bankName: bankName, last4: last4, cardType: cardType, deleted: accountDeleted) }
    /// 合成一单时整单的金额（同一币种）；不是合单时是这一笔的金额
    public var orderTotalMinor: Int64 {
        orderParts.isEmpty ? record.amountMinor : orderParts.filter { $0.currency == record.currency }.map(\.amountMinor).reduce(0, +)
    }
}

/// 账户不持有的币种的交易：银行大概率按账户主币种结汇扣款。
/// 用户填写了实际扣款就用它；否则按交易当天的汇率估算，那天没有汇率就用记录当天的，都没有就用日期最近的一天。
public struct RecordCharge: Hashable, Sendable {
    /// 账户主币种
    public var currency: CurrencyCode
    /// 扣款金额（最小单位，正数）；还没有任何汇率时为 nil
    public var amountMinor: Int64?
    /// 用户填写的实际扣款；false 表示按汇率估算
    public var isActual: Bool
    /// 估算用的汇率日期（`YYYY-MM-DD`）
    public var rateDay: String?

    public init(currency: CurrencyCode, amountMinor: Int64?, isActual: Bool, rateDay: String?) {
        self.currency = currency
        self.amountMinor = amountMinor
        self.isActual = isActual
        self.rateDay = rateDay
    }
}

/// 用户修改一笔流水。
/// 编辑转帐时选的另一边
public enum TransferPeerChange: Hashable, Sendable {
    /// 不改
    case keep
    /// 自己的另一个账户：那个账户里有对得上的流水就配成一对，没有就在那边补记一笔
    case account(String)
    /// 自己的、但没有添加到 App 的账户：不配对
    case untracked
}

public struct RecordEdit: Hashable, Sendable {
    public var accountID: String
    /// 最小货币单位，必须大于 0
    public var amountMinor: Int64
    public var currency: CurrencyCode
    public var direction: FlowDirection
    public var kind: TransactionKind
    /// 空白视为没有
    public var counterparty: String?
    /// 交易时间；nil 表示不修改
    public var time: Date?
    public var note: String
    /// 实际扣款（账户主币种的最小单位）；nil 表示按汇率估算。只在账户不持有 `currency` 时保存
    public var settlementMinor: Int64?
    /// 分类；nil 时保持原来的分类（`keepsCategory`）或改成待分类
    public var categoryID: String?
    /// true：不改分类（只改金额、时间等）
    public var keepsCategory: Bool
    /// 没配对的转账：对方是自己还是别人；nil 时保持原样
    public var transferParty: TransferParty?
    /// 转帐的另一边是哪个账户
    public var peer: TransferPeerChange
    /// 转帐另一边的金额和币种（这一笔转出时是到账多少）；nil 时手动补记的另一边跟着这一笔，银行通知记的不改
    public var peerAmountMinor: Int64?
    public var peerCurrency: CurrencyCode?

    public init(
        accountID: String, amountMinor: Int64, currency: CurrencyCode, direction: FlowDirection, kind: TransactionKind,
        counterparty: String?, time: Date?, note: String, settlementMinor: Int64? = nil,
        categoryID: String? = nil, keepsCategory: Bool = true, transferParty: TransferParty? = nil, peer: TransferPeerChange = .keep,
        peerAmountMinor: Int64? = nil, peerCurrency: CurrencyCode? = nil
    ) {
        self.accountID = accountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.direction = direction
        self.kind = kind
        self.counterparty = counterparty
        self.time = time
        self.note = note
        self.settlementMinor = settlementMinor
        self.categoryID = categoryID
        self.keepsCategory = keepsCategory
        self.transferParty = transferParty
        self.peer = peer
        self.peerAmountMinor = peerAmountMinor
        self.peerCurrency = peerCurrency
    }

    /// 编辑页选了支出 / 收入 / 转帐：换成对应的方向和交易性质（尽量保留原来的性质）。
    /// 转进信用卡算还款（`accountIsCredit`：这笔流水的账户是信用卡）
    public static func fields(
        for type: EntryType, refund: Bool, transferDirection: FlowDirection, original: LedgerRecord, accountIsCredit: Bool = false
    ) -> (direction: FlowDirection, kind: TransactionKind, party: TransferParty?) {
        let kind = original.kind
        switch type {
        case .expense where refund:
            return (.inflow, kind == .refund || kind == .reversal ? kind : .refund, nil)
        case .expense:
            if kind == .transferOut { return (.outflow, kind, .other) }
            return (.outflow, [.purchase, .fee, .interestCharge, .other].contains(kind) ? kind : .purchase, nil)
        case .income:
            if kind == .transferIn { return (.inflow, kind, .other) }
            return (.inflow, [.income, .salary, .interestIncome, .other].contains(kind) ? kind : .income, nil)
        case .transfer:
            let direction = transferDirection
            switch kind {
            case .repayment: return (direction, kind, nil)
            case .deposit where direction == .inflow, .withdrawal where direction == .outflow: return (direction, kind, nil)
            default:
                if accountIsCredit, direction == .inflow { return (direction, .repayment, nil) }
                return (direction, direction == .outflow ? .transferOut : .transferIn, .own)
            }
        }
    }
}

/// 手动记一笔：现金、电子钱包，或者通知还没接上的消费。
public struct ManualEntry: Hashable, Sendable {
    public var type: EntryType
    /// 支出、收入记到的账户；转帐时是转出的账户
    public var accountID: String
    /// 转帐时转入的账户；可以和转出的账户相同（同一个账户两个币种之间换汇）
    public var toAccountID: String?
    /// 最小货币单位，必须大于 0
    public var amountMinor: Int64
    public var currency: CurrencyCode
    /// 转帐时到账多少、到账的币种：有手续费、换汇时和转出不一样；nil 时和转出一样
    public var toAmountMinor: Int64?
    public var toCurrency: CurrencyCode?
    public var categoryID: String?
    /// 支出里的退款（从支出里减掉）
    public var isRefund: Bool
    public var counterparty: String?
    public var note: String
    public var time: Date
    /// 账户（转帐时是转出的账户）没有这个币种时，实际扣款或入账多少账户主币种；nil 按交易当天的汇率估算
    public var settlementMinor: Int64?

    public init(
        type: EntryType, accountID: String, toAccountID: String? = nil, amountMinor: Int64, currency: CurrencyCode,
        toAmountMinor: Int64? = nil, toCurrency: CurrencyCode? = nil,
        categoryID: String? = nil, isRefund: Bool = false, counterparty: String? = nil, note: String = "", time: Date,
        settlementMinor: Int64? = nil
    ) {
        self.type = type
        self.accountID = accountID
        self.toAccountID = toAccountID
        self.amountMinor = amountMinor
        self.currency = currency
        self.toAmountMinor = toAmountMinor
        self.toCurrency = toCurrency
        self.categoryID = categoryID
        self.isRefund = isRefund
        self.counterparty = counterparty
        self.note = note
        self.time = time
        self.settlementMinor = settlementMinor
    }
}

/// 查流水的条件。都不填时是全部流水。
public struct RecordFilter: Hashable, Sendable {
    public var accountID: String?
    /// 只看影响这个币种余额的流水（同时指定 `accountID`）：主币种还包括这张卡不持有的币种的交易（按主币种扣款）
    public var currency: CurrencyCode?
    public var direction: FlowDirection?
    /// 时间范围（按 `effectiveAt`）：含 `from`，不含 `to`
    public var from: Date?
    public var to: Date?
    /// 关键字，空格分开的每个词都要对上：交易对方、备注、账户名称、银行、尾号、交易性质、分类或金额
    public var text: String
    /// 只看支出 / 收入 / 转帐
    public var entryType: EntryType?
    /// 只看这个分类（大类包括它的小类）；`RecordFilter.uncategorized` 只看待分类
    public var categoryID: String?
    /// 首页的看法：只列已入账的；配对的转帐两边合成一行（只留转出那边）；合成一单的几笔只留一行
    public var feed: Bool
    /// 同一条通知拆出的手续费合到那一笔下面，不单列
    public var mergeFees: Bool

    public init(
        accountID: String? = nil, currency: CurrencyCode? = nil, direction: FlowDirection? = nil, from: Date? = nil, to: Date? = nil,
        text: String = "", entryType: EntryType? = nil, categoryID: String? = nil, feed: Bool = false, mergeFees: Bool = false
    ) {
        self.accountID = accountID
        self.currency = currency
        self.direction = direction
        self.from = from
        self.to = to
        self.text = text
        self.entryType = entryType
        self.categoryID = categoryID
        self.feed = feed
        self.mergeFees = mergeFees
    }

    /// `categoryID` 取这个值时只看待分类（支出、收入还没有分类）
    public static let uncategorized = "__uncategorized__"
}

/// 分页游标：按 (effectiveAt, id) 倒序。
public struct RecordCursor: Hashable, Sendable {
    public var effectiveAt: Date
    public var id: String

    public init(effectiveAt: Date, id: String) {
        self.effectiveAt = effectiveAt
        self.id = id
    }
}

/// 记录的来源证据（同一笔交易可能同时有短信和邮件）。
public struct RecordEvidence: Hashable, Sendable {
    public var ingestID: String
    public var source: SourceKind
    public var sender: String?
    public var receivedAt: Date?
    public var processedAt: Date
    public var rawText: String?

    public init(ingestID: String, source: SourceKind, sender: String?, receivedAt: Date?, processedAt: Date, rawText: String?) {
        self.ingestID = ingestID
        self.source = source
        self.sender = sender
        self.receivedAt = receivedAt
        self.processedAt = processedAt
        self.rawText = rawText
    }
}

public struct RecordDetail: Hashable, Sendable {
    public var row: RecordRow
    public var evidence: [RecordEvidence]
    public var transferPeer: RecordRow?
    public var related: RecordRow?
    /// 关联到这一笔的退款
    public var refunds: [RecordRow]
    /// 同一条通知拆出的手续费
    public var fee: RecordRow?
    /// 同一单的其他几笔
    public var orderMembers: [RecordRow]

    public init(
        row: RecordRow, evidence: [RecordEvidence], transferPeer: RecordRow?, related: RecordRow?,
        refunds: [RecordRow] = [], fee: RecordRow? = nil, orderMembers: [RecordRow] = []
    ) {
        self.row = row
        self.evidence = evidence
        self.transferPeer = transferPeer
        self.related = related
        self.refunds = refunds
        self.fee = fee
        self.orderMembers = orderMembers
    }
}
