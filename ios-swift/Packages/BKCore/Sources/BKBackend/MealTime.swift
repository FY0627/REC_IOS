import Foundation
import BKModel
import BKDatabase

/// 一天里的时段（ADR 0026）：早餐、午餐、晚餐的饭点，其余不是饭点。
/// 学分类按时段分开记（`CategoryLearner`）：不是饭点时选了一次别的分类，饭点的自动归类不受影响；三餐按时段推测是哪一餐
enum MealSlot: String, CaseIterable, Sendable {
    case breakfast, lunch, dinner, other

    /// 这一餐对应的默认分类（`CategoryKey`）；不是饭点没有
    var mealKey: String? {
        switch self {
        case .breakfast: CategoryKey.breakfast
        case .lunch: CategoryKey.lunch
        case .dinner: CategoryKey.dinner
        case .other: nil
        }
    }

    /// 三餐之一的分类是哪一餐；别的分类是 nil
    static func meal(of category: LedgerCategory) -> MealSlot? {
        guard let key = category.autoKey else { return nil }
        return [MealSlot.breakfast, .lunch, .dinner].first { $0.mealKey == key }
    }
}

/// 三餐的饭点，按一天里的分钟数（左闭右开）。
///
/// 先用默认的：5–10 点早餐、10–14 点午餐、16 点以后晚餐，14–16 点和 0–5 点不是饭点。
/// 用户自己记成这一餐的流水够 5 笔，这一餐就换成这些流水时间的中位数前后 90 分钟。两餐的范围重叠时算离得近的那一餐
struct MealTimes: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        var slot: MealSlot
        var center: Int
        var range: Range<Int>
    }

    var windows: [Window]

    static let defaults = MealTimes(windows: [
        Window(slot: .breakfast, center: 450, range: 300..<600),
        Window(slot: .lunch, center: 720, range: 600..<840),
        Window(slot: .dinner, center: 1200, range: 960..<1440),
    ])
    /// 一餐至少有几笔自己的流水，才按自己的时间算
    static let minimumRecords = 5
    /// 自己的饭点前后各多少分钟
    static let halfWidth = 90
    /// 看最近多少笔
    static let recent = 60

    func slot(minute: Int) -> MealSlot {
        windows.filter { $0.range.contains(minute) }.min { abs($0.center - minute) < abs($1.center - minute) }?.slot ?? .other
    }

    /// 这个账本的饭点：记成早餐、午餐、晚餐（默认分类里的那三个）的流水够多的，按它们的时间
    static func load(_ db: SQLiteConnection, tree: CategoryTree, calendar: Calendar) throws -> MealTimes {
        var windows: [Window] = []
        for window in defaults.windows {
            guard let key = window.slot.mealKey, let category = tree.category(autoKey: key) else {
                windows.append(window)
                continue
            }
            let minutes = try RecordDAO.recent(db, categoryID: category.id, limit: recent).map { minuteOfDay($0, calendar: calendar) }.sorted()
            guard minutes.count >= minimumRecords else {
                windows.append(window)
                continue
            }
            let median = minutes[minutes.count / 2]
            windows.append(Window(slot: window.slot, center: median, range: max(0, median - halfWidth)..<min(1440, median + halfWidth)))
        }
        return MealTimes(windows: windows)
    }

    /// 交易在一天里的第几分钟：通知写了时分按它，没写按收到的时间
    static func minuteOfDay(_ record: LedgerRecord, calendar: Calendar) -> Int {
        if let time = record.transactionTime, let hour = time.hour, let minute = time.minute { return hour * 60 + minute }
        let c = calendar.dateComponents([.hour, .minute], from: record.effectiveAt)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
