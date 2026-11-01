import SwiftUI
import BKModel

/// 一段时间的支出（减去退款）、收入、结余，所有币种换算成主要币种（首页的本月合计、统计页的总览）。
/// 外币交易有实际扣款的用实际扣款，否则按当天的汇率；还没有汇率的币种不算进去，只有这时多一行小字
struct ConvertedTotalsView: View {
    let total: MonthStats.ConvertedTotals?
    var expenseTitle = "支出"
    var incomeTitle = "收入"

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
                .padding(.top, 12)
                if !total.unconverted.isEmpty {
                    Text("\(total.unconverted.map(\.chineseName).joined(separator: "、"))没有汇率，没算进去")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                }
            } else {
                Text("—").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
