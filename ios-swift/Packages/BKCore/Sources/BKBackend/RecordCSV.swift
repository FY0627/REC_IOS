import Foundation
import BKModel

/// 导出流水：每笔一行的 CSV，Numbers、Excel 都能打开。
///
/// - 开头带 BOM，Excel 才认得出是 UTF-8 的中文；换行用 CRLF；
/// - 金额带正负号（流入为正、流出为负），按币种的小数位、不加千位分隔，表格里能直接加减；
/// - 配对的转帐两边各一行；冻结、解冻也在里面，看「状态」一列。
enum RecordCSV {
    static let header = [
        "时间", "类型", "分类", "小类", "金额", "币种", "账户", "转帐另一边", "交易对方", "备注", "交易性质", "状态", "来源", "自动归类",
        "扣款币种", "实际扣款",
    ]

    static func make(_ rows: [RecordRow], calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = [header] + rows.map { fields($0, formatter: formatter) }
        return "\u{FEFF}" + lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func fields(_ row: RecordRow, formatter: DateFormatter) -> [String] {
        let r = row.record
        let signed = r.direction == .inflow ? r.amountMinor : -r.amountMinor
        // 小类写在「小类」一列，大类在「分类」一列；待分类两列都空
        let category = row.category
        let charged = row.isConverted ? row.chargedCurrency : nil
        let actual = r.settlementMinor.flatMap { minor in charged.map { MoneyFormat.plain(minor, exponent: $0.minorUnitExponent, grouping: false) } }
        return [
            formatter.string(from: r.effectiveAt),
            r.entryType.displayName,
            category.map { $0.parentName ?? $0.name } ?? "",
            category.flatMap { $0.parentName == nil ? nil : $0.name } ?? "",
            MoneyFormat.plain(signed, exponent: r.currency.minorUnitExponent, grouping: false),
            r.currency.rawValue,
            row.account.text,
            row.peer?.text ?? "",
            r.counterparty ?? "",
            r.note,
            r.kind.displayName,
            r.status.displayName,
            r.source.displayName,
            r.categoryAuto ? "是" : "",
            charged?.rawValue ?? "",
            actual ?? "",
        ]
    }

    /// 有逗号、引号、换行的整格用引号括起来，里面的引号写两遍
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
