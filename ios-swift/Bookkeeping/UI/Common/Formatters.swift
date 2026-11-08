import Foundation
import BKModel

/// 展示用格式化。金额全部走整数格式化（`MoneyFormat`），不经过 Double。
/// 日期、时间按选的语言（`AppLanguage`）的习惯写：简体「11月8日 周六」、台湾「11月8日 週六」、英文「Sat, Nov 8」；
/// 12 / 24 小时制跟着系统设置。
enum Fmt {
    static var calendar: Calendar { .current }

    static func money(_ minor: Int64, _ currency: CurrencyCode) -> String {
        MoneyFormat.string(Money(minorUnits: minor, currency: currency))
    }

    static func signed(_ record: LedgerRecord) -> String {
        MoneyFormat.signed(record.amountMinor, currency: record.currency, direction: record.direction)
    }

    /// 时分：简体「14:30」；台湾、英文按当地习惯（「下午2:30」「2:30 PM」），系统选了 24 小时制时都是「14:30」
    static func time(_ date: Date) -> String {
        format(date, "jmm")
    }

    /// 「今天」「昨天」「11月8日 周六」「2025年12月31日」
    static func day(_ date: Date, now: Date = Date()) -> String {
        if let relative = relativeDay(date, now: now) { return relative }
        return format(date, isThisYear(date, now: now) ? "MMMdEEE" : "yMMMd")
    }

    /// 「今天 14:30」「11月8日 14:30」「2025年12月31日 14:30」；英文「Today at 2:30 PM」「Nov 8, 2:30 PM」
    static func dateTime(_ date: Date, now: Date = Date()) -> String {
        if relativeDay(date, now: now) != nil { return relativeFormatter().string(from: date) }
        return format(date, isThisYear(date, now: now) ? "MMMdjmm" : "yMMMdjmm")
    }

    /// 「2026年11月」「November 2026」
    static func monthTitle(year: Int, month: Int) -> String {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "\(year)-\(month)" }
        return format(date, "yMMMM")
    }

    /// 「10月1日」；不是今年时带年份
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        format(date, isThisYear(date, now: now) ? "MMMd" : "yMMMd")
    }

    /// 汇率的日期 `2026-10-24` → 「10月24日」；不是今年时带年份
    static func rateDay(_ key: String, now: Date = Date()) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
        return shortDate(date, now: now)
    }

    /// 卡里没有的币种的交易按主币种扣的款：估算的写「约」，用户填的实际金额写「合」，还没有汇率写「缺汇率」
    static func charge(_ charge: RecordCharge) -> String {
        guard let amount = charge.amountMinor else { return L("缺汇率") }
        let text = money(amount, charge.currency)
        return charge.isActual ? L("合 \(text)") : L("约 \(text)")
    }

    /// 通知正文里写的时间（可能只有日期或只有时分，年份可能是推断的）
    static func wallClock(_ t: WallClock) -> String {
        var parts: [String] = []
        if let month = t.month, let day = t.day {
            let year = t.year ?? calendar.component(.year, from: Date())
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                parts.append(format(date, t.year != nil && !t.yearInferred ? "yMMMd" : "MMMd"))
            }
        }
        if let hour = t.hour, let minute = t.minute { parts.append(clock(hour, minute)) }
        return parts.joined(separator: " ")
    }

    /// 列表里的交易时间：优先显示通知正文写明的时间，否则显示系统接收/处理时间。
    static func recordTime(_ r: LedgerRecord) -> String {
        if let t = r.transactionTime, t.hasTime || t.hasDate { return wallClock(t) }
        return time(r.effectiveAt)
    }

    /// 按收到那天分组的列表里（首页）只写时间，日期在分组标题上；
    /// 通知写的交易日期不是收到那天时（例如隔天才发通知）仍写上日期，免得看错是哪天
    static func recordClock(_ r: LedgerRecord) -> String {
        guard let t = r.transactionTime else { return time(r.effectiveAt) }
        if let month = t.month, let day = t.day {
            let received = calendar.dateComponents([.month, .day], from: r.effectiveAt)
            if received.month != month || received.day != day { return wallClock(t) }
        }
        guard let hour = t.hour, let minute = t.minute else { return time(r.effectiveAt) }
        return clock(hour, minute)
    }

    // MARK: 内部

    private static func relativeDay(_ date: Date, now: Date) -> String? {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return L("今天") }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) { return L("昨天") }
        return nil
    }

    private static func isThisYear(_ date: Date, now: Date) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }

    /// 通知里写的时分（不是某一刻，没有时区）按当地习惯写
    private static func clock(_ hour: Int, _ minute: Int) -> String {
        var c = DateComponents()
        c.calendar = calendar
        c.year = 2000
        c.month = 1
        c.day = 1
        c.hour = hour
        c.minute = minute
        guard let date = calendar.date(from: c) else { return String(format: "%02d:%02d", hour, minute) }
        return time(date)
    }

    /// 按模板（「MMMdEEE」这类）和选的语言格式化。格式化器按语言和模板缓存，换语言后用新的
    private static func format(_ date: Date, _ template: String) -> String {
        formatter(template).string(from: date)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        let locale = displayLocale
        let key = locale.identifier + "|" + template
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }

    /// 「今天」「昨天」加时分，用系统的说法（英文「Today at 2:30 PM」）
    private static func relativeFormatter() -> DateFormatter {
        let locale = displayLocale
        let key = locale.identifier + "|relative"
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatters[key] = formatter
        return formatter
    }

    /// 选的语言，加上系统的 12 / 24 小时制设置
    private static var displayLocale: Locale {
        var components = Locale.Components(locale: AppLanguage.locale)
        components.hourCycle = Locale.current.hourCycle
        return Locale(components: components)
    }
}

extension TransactionKind {
    var symbolName: String {
        switch self {
        case .purchase: "cart"
        case .income: "arrow.down.circle"
        case .salary: "briefcase"
        case .transferIn: "arrow.down.left.circle"
        case .transferOut: "arrow.up.right.circle"
        case .refund: "arrow.uturn.backward.circle"
        case .repayment: "checkmark.circle"
        case .interestCharge: "percent"
        case .fee: "doc.text"
        case .deposit: "tray.and.arrow.down"
        case .withdrawal: "banknote"
        case .interestIncome: "chart.line.uptrend.xyaxis"
        case .reversal: "arrow.uturn.left.square"
        case .other: "circle.dashed"
        }
    }
}

extension Notification.Name {
    /// 自动记账在 App 进程内写入数据后发出，界面据此刷新。
    static let ledgerDidChange = Notification.Name("bk.ledgerDidChange")
}
