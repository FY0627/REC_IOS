import SwiftUI
import BKModel

/// 分类建议体检（「自动记账状态」里进来）：拿已经选好分类的流水，按时间从早到晚一笔笔重新推荐，每笔只用它之前的记录，
/// 看建议准不准（`CategoryCheckup`）。不用等新账单，打开就算；只读，不改账本，也不改学到的规律。下拉重新算
struct CategoryCheckupView: View {
    @Environment(LedgerStore.self) private var store
    @State private var checkup: CategoryCheckup?
    @State private var errorText: String?

    var body: some View {
        List {
            if let checkup {
                results(checkup)
            } else if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在算…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("分类建议体检")
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
        .refreshable { await run() }
    }

    @ViewBuilder
    private func results(_ checkup: CategoryCheckup) -> some View {
        Section {
            LabeledContent("算了几笔", value: "\(checkup.all.count) 笔")
            LabeledContent("自动记账记的", value: "\(checkup.automatic) 笔")
            LabeledContent("认得出商户的", value: ratio(checkup.withMerchant.count, of: checkup.all.count))
        } footer: {
            Text("拿你已经选好分类的流水，按时间从早到晚一笔笔重新推荐，每笔只用它之前的记录。自动归类的，和手续费、利息、工资、退款这些通知写明的不算。")
        }
        if checkup.all.count > 0 {
            score("全部", checkup.all, footer: "长按通知、点一个按钮各算一下；先选大类再选小类、打开 App 选的，按实际要点的步骤算；自动归对的算 0 下。")
            score("认得出商户的", checkup.withMerchant)
            score("看不出商户的", checkup.withoutMerchant)
            Section {
                ForEach(Array(checkup.autoFiling.enumerated()), id: \.element.streak) { index, item in
                    LabeledContent("连续 \(item.streak) 次" + (index == 0 ? "（现在）" : ""), value: "归 \(item.filed) 笔，错 \(item.wrong) 笔")
                }
            } header: {
                Text("同一个商户连续选几次就自动归类")
            } footer: {
                Text("只有认得出商户的才会自动归类。「错」是会自动归到的分类和你选的不一样。")
            }
        }
    }

    private func score(_ title: String, _ score: CategoryCheckup.Score, footer: String? = nil) -> some View {
        Section {
            LabeledContent("第 1 个建议就对", value: ratio(score.first, of: score.count))
            LabeledContent("面板的建议里有", value: ratio(score.panel, of: score.count))
            LabeledContent("通知的大类按钮里有", value: ratio(score.notification, of: score.count))
            LabeledContent("在通知上平均点几下", value: score.averageTaps.map { String(format: "%.1f 下", $0) } ?? "—")
        } header: {
            Text("\(title)（\(score.count) 笔）")
        } footer: {
            if let footer { Text(footer) }
        }
    }

    /// 「62%（31/50）」；一笔都没有时写「—」
    private func ratio(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return "\(Int((Double(part) * 100 / Double(total)).rounded()))%（\(part)/\(total)）"
    }

    private func run() async {
        do {
            checkup = try await store.categoryCheckup()
            errorText = nil
        } catch {
            errorText = "算不出来：\(error.localizedDescription)"
        }
    }
}
