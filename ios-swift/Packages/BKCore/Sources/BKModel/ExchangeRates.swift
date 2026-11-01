import Foundation

/// 汇率快照：1 个 `base` 等于多少其他币种。账本里的金额始终是原币种整数；
/// 汇率只用于资产页换算净资产，和估算外币交易按主币种扣了多少（`RecordCharge`）。
public struct ExchangeRates: Hashable, Sendable, Codable {
    public var base: CurrencyCode
    /// 币种代码 → 1 个 base 可兑换的数量
    public var rates: [String: Double]
    /// 数据源的更新时间
    public var updatedAt: Date
    /// 本机下载的时间
    public var fetchedAt: Date

    public init(base: CurrencyCode, rates: [String: Double], updatedAt: Date, fetchedAt: Date) {
        self.base = base
        self.rates = rates
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
    }

    public func rate(_ currency: CurrencyCode) -> Double? {
        if currency == base { return 1 }
        guard let value = rates[currency.rawValue], value > 0, value.isFinite else { return nil }
        return value
    }

    public func canConvert(_ from: CurrencyCode, to: CurrencyCode) -> Bool {
        from == to || (rate(from) != nil && rate(to) != nil)
    }

    /// 最小货币单位之间换算（按两种币种各自的小数位数），四舍五入到目标币种的最小单位；缺汇率时返回 nil。
    public func convert(_ minor: Int64, from: CurrencyCode, to: CurrencyCode) -> Int64? {
        if from == to { return minor }
        guard let fromRate = rate(from), let toRate = rate(to) else { return nil }
        return Self.convert(minor, from: from, rate: fromRate, to: to, rate: toRate)
    }

    /// 两个币种相对同一个基准的汇率（1 个基准可兑换的数量）
    public static func convert(_ minor: Int64, from: CurrencyCode, rate fromRate: Double, to: CurrencyCode, rate toRate: Double) -> Int64? {
        guard fromRate > 0, toRate > 0, fromRate.isFinite, toRate.isFinite else { return nil }
        let major = Double(minor) / pow(10, Double(from.minorUnitExponent))
        let converted = major / fromRate * toRate * pow(10, Double(to.minorUnitExponent))
        guard converted.isFinite, abs(converted) < 9e15 else { return nil }
        return Int64(converted.rounded())
    }
}

/// 汇率按天保存，日期是手机所在时区的 `YYYY-MM-DD`。
public enum RateDay {
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return key(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    public static func key(year: Int, month: Int, day: Int) -> String {
        pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }
}
