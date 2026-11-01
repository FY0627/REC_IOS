import Foundation

/// 币种代码（ISO 4217）。只保存代码本身，不从设备地区推断。
public struct CurrencyCode: Hashable, Sendable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(_ code: String) {
        self.init(rawValue: code)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: CurrencyCode, rhs: CurrencyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 最小货币单位的小数位数。
    public var minorUnitExponent: Int { Self.exponents[rawValue] ?? 2 }

    private static let exponents: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "ISK": 0, "CLP": 0, "PYG": 0, "UGX": 0,
        "BIF": 0, "DJF": 0, "GNF": 0, "KMF": 0, "RWF": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "KWD": 3, "OMR": 3, "JOD": 3, "TND": 3, "IQD": 3, "LYD": 3,
    ]

    /// 汇率数据源（ExchangeRate-API）支持的全部币种，添加账户、选主要币种时都可以选。
    public static let supported: [CurrencyCode] = """
        AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD
        CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP FOK GBP GEL GGP GHS
        GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS IMP INR IQD IRR ISK JEP JMD JOD JPY KES KGS KHR KID
        KMF KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN
        NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD
        SHP SLE SLL SOS SRD SSP STN SYP SZL THB TJS TMT TND TOP TRY TTD TVD TWD TZS UAH UGX USD UYU UZS VES
        VND VUV WST XAF XCD XCG XDR XOF XPF YER ZAR ZMW ZWL
        """.split(whereSeparator: \.isWhitespace).map { CurrencyCode(String($0)) }

    public static let cny = CurrencyCode("CNY")
    public static let eur = CurrencyCode("EUR")
    public static let usd = CurrencyCode("USD")
    public static let hkd = CurrencyCode("HKD")
    public static let gbp = CurrencyCode("GBP")
    public static let jpy = CurrencyCode("JPY")
    public static let chf = CurrencyCode("CHF")

    /// 添加账户时可选的常用币种（顺序只是展示顺序，不代表默认值）。
    public static let common: [CurrencyCode] = [
        .cny, .eur, .usd, .hkd, .gbp, .jpy, .chf,
        CurrencyCode("SGD"), CurrencyCode("AUD"), CurrencyCode("CAD"), CurrencyCode("MOP"),
        CurrencyCode("TWD"), CurrencyCode("KRW"), CurrencyCode("SEK"), CurrencyCode("NOK"),
        CurrencyCode("DKK"), CurrencyCode("PLN"), CurrencyCode("CZK"), CurrencyCode("HUF"),
    ]

    public var symbol: String {
        switch rawValue {
        case "CNY": "¥"
        case "EUR": "€"
        case "USD": "US$"
        case "HKD": "HK$"
        case "GBP": "£"
        case "JPY": "JP¥"
        case "MOP": "MOP$"
        case "TWD": "NT$"
        case "SGD": "S$"
        case "AUD": "A$"
        case "CAD": "C$"
        case "KRW": "₩"
        default: rawValue + " "
        }
    }

    /// 中文名称：常用币种用习惯叫法（港币、澳元），其他用系统提供的名称
    public var chineseName: String {
        if let name = Self.chineseNames[rawValue] { return name }
        return Self.localizedName(rawValue, in: Self.simplifiedChinese) ?? rawValue
    }

    public var englishName: String {
        if let name = Self.englishNames[rawValue] { return name }
        return Self.localizedName(rawValue, in: Self.english) ?? rawValue
    }

    private static let simplifiedChinese = Locale(identifier: "zh_Hans")
    private static let english = Locale(identifier: "en")

    /// 系统没有名称时返回 nil（有的系统直接返回代码本身）
    private static func localizedName(_ code: String, in locale: Locale) -> String? {
        guard let name = locale.localizedString(forCurrencyCode: code), name.uppercased() != code else { return nil }
        return name
    }

    private static let chineseNames: [String: String] = [
        "CNY": "人民币", "EUR": "欧元", "USD": "美元", "HKD": "港币", "GBP": "英镑", "JPY": "日元", "CHF": "瑞士法郎",
        "SGD": "新加坡元", "AUD": "澳元", "CAD": "加元", "MOP": "澳门元", "TWD": "新台币", "KRW": "韩元",
        "SEK": "瑞典克朗", "NOK": "挪威克朗", "DKK": "丹麦克朗", "PLN": "波兰兹罗提", "CZK": "捷克克朗", "HUF": "匈牙利福林",
        "NZD": "新西兰元", "THB": "泰铢", "MYR": "马来西亚林吉特", "PHP": "菲律宾比索", "IDR": "印尼盾", "VND": "越南盾",
        "INR": "印度卢比", "AED": "阿联酋迪拉姆", "SAR": "沙特里亚尔", "RUB": "俄罗斯卢布", "TRY": "土耳其里拉",
        "BRL": "巴西雷亚尔", "MXN": "墨西哥比索", "ZAR": "南非兰特",
        // 数据源里有、但不是国际标准代码的属地货币
        "FOK": "法罗群岛克朗", "GGP": "根西岛镑", "IMP": "马恩岛镑", "JEP": "泽西岛镑", "KID": "基里巴斯元", "TVD": "图瓦卢元",
        "XCG": "加勒比盾",
    ]

    private static let englishNames: [String: String] = [
        "FOK": "Faroese Króna", "GGP": "Guernsey Pound", "IMP": "Manx Pound", "JEP": "Jersey Pound",
        "KID": "Kiribati Dollar", "TVD": "Tuvaluan Dollar", "XCG": "Caribbean Guilder",
    ]
}

/// 金额：最小货币单位的整数 + 币种。账务运算全部用整数，不经过 Float/Double。
public struct Money: Hashable, Sendable, Codable {
    public var minorUnits: Int64
    public var currency: CurrencyCode

    public init(minorUnits: Int64, currency: CurrencyCode) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// 币种不同时返回 nil，调用方必须按币种分别汇总。
    public func adding(_ other: Money) -> Money? {
        guard other.currency == currency else { return nil }
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        return overflow ? nil : Money(minorUnits: sum, currency: currency)
    }

    public var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }
}

public enum MoneyFormat {
    /// 与地区设置无关的金额文本，例如 `1,234.56`。
    public static func plain(_ minorUnits: Int64, exponent: Int, grouping: Bool = true) -> String {
        let negative = minorUnits < 0
        let magnitude = minorUnits.magnitude
        var divisor: UInt64 = 1
        for _ in 0..<max(0, exponent) { divisor *= 10 }
        let integerPart = magnitude / divisor
        let fraction = magnitude % divisor
        var integerText = String(integerPart)
        if grouping, integerText.count > 3 {
            var grouped = ""
            for (offset, character) in integerText.enumerated() {
                if offset > 0, (integerText.count - offset) % 3 == 0 { grouped.append(",") }
                grouped.append(character)
            }
            integerText = grouped
        }
        var text = integerText
        if exponent > 0 {
            var fractionText = String(fraction)
            while fractionText.count < exponent { fractionText = "0" + fractionText }
            text += "." + fractionText
        }
        return negative ? "-" + text : text
    }

    public static func string(_ money: Money, grouping: Bool = true) -> String {
        let body = plain(money.minorUnits, exponent: money.currency.minorUnitExponent, grouping: grouping)
        if body.hasPrefix("-") { return "-" + money.currency.symbol + body.dropFirst() }
        return money.currency.symbol + body
    }

    /// 带方向符号：流入 `+`，流出 `-`。
    public static func signed(_ minorUnits: Int64, currency: CurrencyCode, direction: FlowDirection) -> String {
        let body = plain(minorUnits, exponent: currency.minorUnitExponent)
        return (direction == .inflow ? "+" : "-") + currency.symbol + body
    }
}
