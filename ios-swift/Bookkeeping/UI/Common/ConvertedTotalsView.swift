import SwiftUI
import BKModel

/// 一段时间的支出（减去退款）、收入、结余，所有币种换算成主要币种（首页的本月合计、统计页的总览）。
/// 外币交易有实际扣款的用实际扣款，否则按当天的汇率；还没有汇率的币种不算进去，只有这时多一行小字
struct ConvertedTotalsView: View {
    let total: MonthStats.ConvertedTotals?
    var expenseTitle: LocalizedStringKey = "支出"
    var incomeTitle: LocalizedStringKey = "收入"

    /// 大数下面那一行离大数的距离；资产页的净资产卡也用，两张卡一样高
    static let figuresTop: CGFloat = 12
    /// 上下多留的边距（在系统给格子留的边距里面）；资产页的净资产卡也用
    static let verticalPadding: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(expenseTitle).font(.subheadline).foregroundStyle(.secondary)
            if let total {
                Text(Fmt.money(total.expenseMinor, total.currency))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 2)
                HStack(alignment: .top, spacing: 20) {
                    stat(incomeTitle, Fmt.money(total.incomeMinor, total.currency))
                    stat("结余", Fmt.money(total.balanceMinor, total.currency))
                }
                .padding(.top, Self.figuresTop)
                if !total.unconverted.isEmpty {
                    Text(L("\(total.unconverted.map(\.localizedName).joined(separator: L("、")))没有汇率"))
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                }
            } else {
                Text("—").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
