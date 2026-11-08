import SwiftUI
import BKModel

/// 分类建议体检（「我的 › 开发与调试」里进来）：拿已经选好分类的流水，按时间从早到晚一笔笔重新推荐，每笔只用它之前的记录，
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
                ProgressView()
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
        }
        if checkup.all.count > 0 {
            score("全部", checkup.all)
            score("认得出商户的", checkup.withMerchant)
            score("看不出商户的", checkup.withoutMerchant)
            Section("自动归类") {
                ForEach(Array(checkup.autoFiling.enumerated()), id: \.element.streak) { index, item in
                    LabeledContent("连续 \(item.streak) 次" + (index == 0 ? "（现在）" : ""), value: "归 \(item.filed) 笔，错 \(item.wrong) 笔")
                }
            }
        }
    }

    private func score(_ title: String, _ score: CategoryCheckup.Score) -> some View {
        Section("\(title)（\(score.count) 笔）") {
            LabeledContent("第 1 个建议就对", value: ratio(score.first, of: score.count))
            LabeledContent("面板的建议里有", value: ratio(score.panel, of: score.count))
            LabeledContent("通知第一页就有", value: ratio(score.notification, of: score.count))
            LabeledContent("在通知上平均点几下", value: score.averageTaps.map { String(format: "%.1f 下", $0) } ?? "—")
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
