import Foundation
import BKModel
import BKDatabase

/// 换成账户另一个币种扣款（入账）的交易扣了多少：账户没有这个币种时银行按主币种结汇；
/// 多币种账户这个币种不够时整笔换成主币种（ADR 0018）。统计换算成「我的」主要币种时也用它。
///
/// 通知写明或用户填写了实际金额（正好是要的币种）就用它；否则按汇率估算。汇率取交易当天的；那天没有就取记录当天（App 处理通知那天）的；
/// 都没有就取日期最近的一天（一样近取更早的）。汇率按天保存在 `RateDAO`，每天一份完整的汇率表。
/// 只在一次数据库读取里使用：缓存读过的日期和汇率表。
final class ChargeCalculator {
    private let db: SQLiteConnection
    private let calendar: Calendar
    private var loadedDays: [String]?
    private var tables: [String: [String: Double]] = [:]

    init(db: SQLiteConnection, calendar: Calendar) {
        self.db = db
        self.calendar = calendar
    }

    /// 这笔折合多少 `target`
    func charge(_ record: LedgerRecord, to target: CurrencyCode) throws -> RecordCharge {
        if let actual = record.settlementMinor, record.chargeCurrency == target {
            return RecordCharge(currency: target, amountMinor: actual, isActual: true, rateDay: nil)
        }
        return try convert(record.amountMinor, record.currency, day: try rateDay(for: record), primary: target)
    }

    /// 还没记下的一笔（手动记一笔时提示）：用 `date` 当天的汇率，那天没有就用日期最近的一天
    func estimate(_ amountMinor: Int64, _ currency: CurrencyCode, at date: Date, primary: CurrencyCode) throws -> RecordCharge {
        let days = try self.days()
        let day = RateDay.key(date, calendar: calendar)
        return try convert(amountMinor, currency, day: Self.contains(days, day) ? day : Self.nearest(days, to: day), primary: primary)
    }

    private func convert(_ amountMinor: Int64, _ currency: CurrencyCode, day: String?, primary: CurrencyCode) throws -> RecordCharge {
        guard let day else { return RecordCharge(currency: primary, amountMinor: nil, isActual: false, rateDay: nil) }
        let table = try rates(day)
        var amount: Int64?
        if let from = table[currency.rawValue], let to = table[primary.rawValue] {
            amount = ExchangeRates.convert(amountMinor, from: currency, rate: from, to: primary, rate: to)
        }
        return RecordCharge(currency: primary, amountMinor: amount, isActual: false, rateDay: day)
    }

    /// 估算用哪一天的汇率；还没有任何汇率时为 nil
    func rateDay(for record: LedgerRecord) throws -> String? {
        let days = try self.days()
        guard !days.isEmpty else { return nil }
        let transactionDay = Self.transactionDay(record, calendar: calendar)
        if Self.contains(days, transactionDay) { return transactionDay }
        let recordedDay = RateDay.key(record.processedAt, calendar: calendar)
        if Self.contains(days, recordedDay) { return recordedDay }
        return Self.nearest(days, to: transactionDay)
    }

    /// 交易当天：通知里写了日期就用它，否则用收到通知的日期
    static func transactionDay(_ record: LedgerRecord, calendar: Calendar) -> String {
        if let time = record.transactionTime, let year = time.year, let month = time.month, let day = time.day {
            return RateDay.key(year: year, month: month, day: day)
        }
        return RateDay.key(record.effectiveAt, calendar: calendar)
    }

    private func days() throws -> [String] {
        if let loadedDays { return loadedDays }
        let days = try RateDAO.days(db)
        loadedDays = days
        return days
    }

    private func rates(_ day: String) throws -> [String: Double] {
        if let table = tables[day] { return table }
        let table = try RateDAO.rates(db, day: day)
        tables[day] = table
        return table
    }

    /// `days` 从早到晚排好
    static func contains(_ days: [String], _ day: String) -> Bool {
        let index = insertionIndex(days, day)
        return index < days.count && days[index] == day
    }

    static func nearest(_ days: [String], to day: String) -> String? {
        guard !days.isEmpty else { return nil }
        let index = insertionIndex(days, day)
        if index == 0 { return days[0] }
        if index == days.count { return days[days.count - 1] }
        let earlier = days[index - 1], later = days[index]
        guard let target = dayNumber(day), let a = dayNumber(earlier), let b = dayNumber(later) else { return earlier }
        return target - a <= b - target ? earlier : later
    }

    private static func insertionIndex(_ days: [String], _ day: String) -> Int {
        var low = 0, high = days.count
        while low < high {
            let mid = (low + high) / 2
            if days[mid] < day { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// `YYYY-MM-DD` → 从 1970-01-01 起的天数（公历）
    static func dayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (m, d) = (parts[1], parts[2])
        let y = m <= 2 ? parts[0] - 1 : parts[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
