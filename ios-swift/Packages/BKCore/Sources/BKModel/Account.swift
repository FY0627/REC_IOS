import Foundation

public enum CardType: String, Sendable, Codable, CaseIterable {
    case debit
    case credit
    case prepaid
    case other
    /// 现金：没有卡号，只能手动记账
    case cash
    /// 自己有余额的电子钱包（微信零钱、支付宝余额）：没有卡号；支付宝、微信支付发来的通知可以自动记到它（`WalletDirectory`）
    case wallet

    public var displayName: String {
        switch self {
        case .debit: "借记卡"
        case .credit: "信用卡"
        case .prepaid: "预付卡"
        case .other: "其他账户"
        case .cash: "现金"
        case .wallet: "电子钱包"
        }
    }

    /// 银行卡（有尾号，参与自动记账匹配）；现金和电子钱包不是
    public var isCard: Bool { self != .cash && self != .wallet }

    /// 添加银行卡、改卡类型时可选的类型
    public static let cardCases: [CardType] = [.debit, .credit, .prepaid, .other]
}

/// 卡面个性化：自定义背景图和文字样式。都为空时使用配色方案的默认样式。
public struct CardFace: Hashable, Sendable, Codable {
    /// 背景图的标识。图片本身保存在 App 的文件目录，不进数据库；每次换图都生成新标识。
    public var imageID: String?
    /// 文字颜色（0xRRGGBB）；nil 时用配色方案的文字颜色，有背景图时用白色。
    public var textColor: UInt32?
    /// 文字大小倍数，1 为默认。
    public var textScale: Double
    /// 背景图上金额的描边颜色（0xRRGGBB）；nil 时用黑色。
    public var outlineColor: UInt32?
    /// 背景图上金额的位置：0 靠左 / 靠上，1 靠右 / 靠下，默认右上角。按比例保存，屏幕大小不同、金额变长都不会跑出卡片。
    public var amountX: Double
    public var amountY: Double

    public init(
        imageID: String? = nil, textColor: UInt32? = nil, textScale: Double = 1,
        outlineColor: UInt32? = nil, amountX: Double = 1, amountY: Double = 0
    ) {
        self.imageID = imageID
        self.textColor = textColor
        self.textScale = textScale
        self.outlineColor = outlineColor
        self.amountX = amountX
        self.amountY = amountY
    }

    public static let standard = CardFace()
    public static let textScaleRange: ClosedRange<Double> = 0.8...1.3
    public static let amountPositionRange: ClosedRange<Double> = 0...1

    public static func clampedAmountPosition(_ value: Double) -> Double {
        min(amountPositionRange.upperBound, max(amountPositionRange.lowerBound, value))
    }
}

/// 某个币种的初始余额：用户填写的「现在」的余额，没有更晚的银行通知余额时，以它为起点推算余额。
public struct OpeningBalance: Hashable, Sendable, Codable {
    public var currency: CurrencyCode
    /// 最小货币单位，可为负（欠款）
    public var amountMinor: Int64
    /// 只有晚于这个时间的流水才加到初始余额上
    public var at: Date

    public init(currency: CurrencyCode, amountMinor: Int64, at: Date) {
        self.currency = currency
        self.amountMinor = amountMinor
        self.at = at
    }
}

/// 银行卡账户。自动记账只用后四位匹配；完整卡号是选填的，只为在卡片信息里查看。不保存密码或邮箱凭据。
/// 多币种账户（例如一张卡里存港币、美元、人民币）：`currency` 是主币种，通知没写币种时记为主币种；
/// 其余币种在 `extraCurrencies`。每个币种的余额分开推算，不互相换算。
/// 账户不持有的币种的交易按主币种扣款，计入主币种余额（`RecordCharge`）。
public struct Account: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// 银行的标识（见 `BankCatalog`；其中能识别通知的在 `BankDirectory`），自己填写的银行为 nil。
    public var bankID: String?
    public var bankName: String
    /// 后四位，字符串保存以保留前导零。
    public var last4: String
    public var cardType: CardType
    /// 主币种
    public var currency: CurrencyCode
    /// 多币种账户的其他币种（不含主币种）；单币种账户为空。
    public var extraCurrencies: [CurrencyCode]
    public var paletteID: String
    public var sortOrder: Int
    public var createdAt: Date
    public var archived: Bool
    /// 删除的时间。删除的账户不再出现在任何账户列表里，它的流水保留，账户名称后面写「已删除」
    public var deletedAt: Date?
    /// 各币种的初始余额（每个币种最多一条）
    public var openingBalances: [OpeningBalance]
    /// 选填的完整卡号（纯数字），末四位必须与 `last4` 一致。
    public var cardNumber: String?
    /// 选填的账号（户口号码），可以是打码的形式，例如 `100-200XXX-300`。
    /// 有的银行通知（尤其是转账邮件）只写账号不写卡号尾号，靠它匹配到这张卡。
    public var accountNumber: String?
    public var face: CardFace

    public init(
        id: String,
        name: String,
        bankID: String?,
        bankName: String,
        last4: String,
        cardType: CardType,
        currency: CurrencyCode,
        extraCurrencies: [CurrencyCode] = [],
        paletteID: String,
        sortOrder: Int,
        createdAt: Date,
        archived: Bool = false,
        deletedAt: Date? = nil,
        openingBalances: [OpeningBalance] = [],
        cardNumber: String? = nil,
        accountNumber: String? = nil,
        face: CardFace = .standard
    ) {
        self.id = id
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.extraCurrencies = Self.normalizedExtras(extraCurrencies, primary: currency)
        self.paletteID = paletteID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.archived = archived
        self.deletedAt = deletedAt
        self.openingBalances = openingBalances
        self.cardNumber = cardNumber
        self.accountNumber = accountNumber
        self.face = face
    }

    /// 账户持有的全部币种，主币种在前。
    public var currencies: [CurrencyCode] { [currency] + extraCurrencies }
    public var isMultiCurrency: Bool { !extraCurrencies.isEmpty }

    public func openingBalance(_ currency: CurrencyCode) -> OpeningBalance? {
        openingBalances.first { $0.currency == currency }
    }

    /// 主币种的初始余额
    public var openingBalanceMinor: Int64? { openingBalance(currency)?.amountMinor }
    public var openingBalanceAt: Date? { openingBalance(currency)?.at }

    /// 去掉重复和主币种，保持原有顺序。
    public static func normalizedExtras(_ extras: [CurrencyCode], primary: CurrencyCode) -> [CurrencyCode] {
        var seen: Set<CurrencyCode> = [primary]
        return extras.filter { seen.insert($0).inserted }
    }

    public static func isValidLast4(_ value: String) -> Bool {
        value.count == 4 && value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// 现金、电子钱包没有卡号：表里的尾号填这个占位，不参与匹配
    public static let placeholderLast4 = "0000"

    /// 银行卡（有尾号，参与自动记账匹配）
    public var isCard: Bool { cardType.isCard }

    /// 通知里写的尾号是不是这张卡。邮储等只写后三位（「尾号017」）
    public func matches(tail: String) -> Bool {
        last4 == tail || (tail.count == 3 && last4.hasSuffix(tail))
    }
    public var deleted: Bool { deletedAt != nil }

    /// 银行卡「招商银行 ·0427」，现金和电子钱包写名称；删除的账户后面写「（已删除）」
    public var displayTitle: String { label.text }
    public var label: AccountLabel { AccountLabel(name: name, bankName: bankName, last4: last4, cardType: cardType, deleted: deleted) }

    /// 没填账户名称时的默认名称，例如「招商银行借记卡」
    public static func defaultName(bankName: String, cardType: CardType) -> String { "\(bankName)\(cardType.displayName)" }

    /// 去掉空格和短横线后的卡号；不是 12–19 位数字时返回 nil。
    public static func normalizedCardNumber(_ input: String) -> String? {
        let digits = String(input.filter { $0 != " " && $0 != "-" })
        guard (12...19).contains(digits.count), digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
        return digits
    }

    /// 整理用户填写的账号：去掉空格，`x`、`*`、`•` 统一成 `X`（打码位），保留短横线方便阅读。
    /// 去掉短横线后必须是 6–30 位数字或 X，且至少有 3 位数字；否则返回 nil。
    public static func normalizedAccountNumber(_ input: String) -> String? {
        var output = ""
        for char in input.uppercased() where char != " " {
            switch char {
            case "0"..."9", "X", "-": output.append(char)
            case "*", "•": output.append("X")
            default: return nil
            }
        }
        let pattern = numberPattern(output)
        guard (6...30).contains(pattern.count), pattern.filter(\.isNumber).count >= 3 else { return nil }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 号码只留数字和打码位 X，用于比较：`100-200xxx-300` → `100200XXX300`
    public static func numberPattern(_ input: String) -> String {
        String(input.uppercased().compactMap { char -> Character? in
            switch char {
            case "0"..."9", "X": char
            case "*", "•": "X"
            default: nil
            }
        })
    }
}

/// 添加账户时由界面填写的内容。
public struct AccountDraft: Sendable, Hashable {
    public var name: String
    public var bankID: String?
    public var bankName: String
    public var last4: String
    public var cardType: CardType
    public var currency: CurrencyCode
    /// 多币种账户的其他币种
    public var extraCurrencies: [CurrencyCode]
    public var paletteID: String
    /// 选填：添加时这张卡主币种的当前余额（最小货币单位，可为负，例如信用卡欠款）。
    public var openingBalanceMinor: Int64?
    /// 选填：其他币种的当前余额
    public var extraOpeningBalances: [CurrencyCode: Int64]

    public init(
        name: String, bankID: String?, bankName: String, last4: String, cardType: CardType, currency: CurrencyCode, paletteID: String,
        openingBalanceMinor: Int64? = nil, extraCurrencies: [CurrencyCode] = [], extraOpeningBalances: [CurrencyCode: Int64] = [:]
    ) {
        self.name = name
        self.bankID = bankID
        self.bankName = bankName
        self.last4 = last4
        self.cardType = cardType
        self.currency = currency
        self.extraCurrencies = extraCurrencies
        self.paletteID = paletteID
        self.openingBalanceMinor = openingBalanceMinor
        self.extraOpeningBalances = extraOpeningBalances
    }

    /// 现金或电子钱包：名称就是它在卡包里显示的名称，没有银行和卡号。电子钱包的 `walletID` 是哪个钱包（`WalletDirectory`）
    public static func pocket(
        name: String, type: CardType, currency: CurrencyCode, paletteID: String, openingBalanceMinor: Int64? = nil, walletID: String? = nil
    ) -> AccountDraft {
        AccountDraft(
            name: name, bankID: type == .wallet ? walletID : nil, bankName: name, last4: Account.placeholderLast4, cardType: type, currency: currency,
            paletteID: paletteID, openingBalanceMinor: openingBalanceMinor
        )
    }
}

/// 卡片信息里修改账户。银行和尾号不能改。
public struct AccountEdit: Sendable, Hashable {
    /// 留空恢复默认名称
    public var name: String
    public var cardType: CardType
    public var currency: CurrencyCode
    public var extraCurrencies: [CurrencyCode]
    /// 选填的完整卡号；nil 或空白清除
    public var cardNumber: String?
    /// 选填的账号；nil 或空白清除
    public var accountNumber: String?
    /// 改了的初始余额。改过的记为「现在」的余额；没列出的币种不变
    public var openingBalanceChanges: [OpeningBalanceChange]

    public init(
        name: String, cardType: CardType, currency: CurrencyCode, extraCurrencies: [CurrencyCode],
        cardNumber: String?, accountNumber: String?, openingBalanceChanges: [OpeningBalanceChange] = []
    ) {
        self.name = name
        self.cardType = cardType
        self.currency = currency
        self.extraCurrencies = extraCurrencies
        self.cardNumber = cardNumber
        self.accountNumber = accountNumber
        self.openingBalanceChanges = openingBalanceChanges
    }
}

public struct OpeningBalanceChange: Sendable, Hashable {
    public var currency: CurrencyCode
    /// 最小货币单位；nil 表示清除
    public var amountMinor: Int64?

    public init(currency: CurrencyCode, amountMinor: Int64?) {
        self.currency = currency
        self.amountMinor = amountMinor
    }
}

public enum AccountValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyBank
    case invalidLast4
    case duplicateAccount
    /// 完整卡号不是 12–19 位数字，或末四位与尾号不一致
    case invalidCardNumber
    /// 账号不是 6–30 位数字或打码位
    case invalidAccountNumber
}
