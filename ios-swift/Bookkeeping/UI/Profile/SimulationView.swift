import SwiftUI
import BKBackend
import BKModel

/// 模拟消费（「我的 › 开发与调试」）：点一个场景，App 假装收到一条银行短信，记在资产里的「模拟卡」上，
/// 和真的短信走同一个流程，几秒后弹出带分类按钮的记账结果通知，长按选分类，体验分类建议（`Simulation`）。
/// 一键清除在按钮弹出的小菜单里再点一下，删掉模拟卡、它的流水和学到的「模拟·」商户
struct SimulationView: View {
    @Environment(LedgerStore.self) private var store
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @State private var count = 0
    @State private var lastText: String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        List {
            if notifyMode != IngestNotifier.Mode.all.rawValue {
                Section {
                    Text("「我的 › 通知 › 记账结果」选「全部」，通知上才有分类按钮。").foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(SimulatedSpend.allCases) { spend in
                    Button { Task { await simulate(spend) } } label: {
                        LabeledContent(spend.title, value: spend.merchant ?? "像中行那样不写商户")
                    }
                }
            } header: {
                Text("点一下，假装付了一笔")
            } footer: {
                Text("用现在的时间和一个随机金额编一条工商银行的短信，和真的短信一样入账。几秒后弹出记账结果通知，长按选分类。商户名前面带「模拟·」，学到的分类不影响真的商户。")
            }
            if let lastText {
                Section { Text(lastText) }
            }
            Section {
                LabeledContent("模拟了", value: "\(count) 笔")
                Menu {
                    Button(role: .destructive) { Task { await clear() } } label: {
                        Label("删掉模拟卡和它的全部流水", systemImage: "trash")
                    }
                } label: {
                    Label("一键清除", systemImage: "trash")
                }
                .disabled(count == 0)
            } footer: {
                Text("模拟的流水记在资产里的「模拟卡」上，清除之前会算进本月支出和分类建议体检。清除会删掉模拟卡、它的流水、模拟的通知和学到的「模拟·」商户。")
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .disabled(busy)
        .navigationTitle("模拟消费")
        .navigationBarTitleDisplayMode(.inline)
        .task { count = await store.simulatedRecordCount() }
    }

    private func simulate(_ spend: SimulatedSpend) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await store.simulateSpend(spend)
            let item = result.items.first
            let amount = item.flatMap { item in item.amountMinor.flatMap { minor in item.currency.map { Fmt.money(minor, $0) } } } ?? ""
            lastText = item?.result == .recorded
                ? "\(spend.title)：记了 \(amount)，看通知。"
                : "\(spend.title)：\(result.summary)"
            count = await store.simulatedRecordCount()
            errorText = nil
        } catch {
            errorText = "模拟失败：\(error.localizedDescription)"
        }
    }

    private func clear() async {
        busy = true
        defer { busy = false }
        do {
            let removed = try await store.clearSimulation()
            lastText = "清除了 \(removed) 笔模拟的流水和模拟卡。"
            count = 0
            errorText = nil
        } catch {
            errorText = "清除失败：\(error.localizedDescription)"
        }
    }
}
