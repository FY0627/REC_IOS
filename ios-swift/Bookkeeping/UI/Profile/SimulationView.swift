import SwiftUI
import BKBackend
import BKModel

/// 模拟消费（「我的 › 开发与调试」）：点一个场景，App 假装收到一条银行短信，记在资产里的「模拟卡」上，
/// 和真的短信走同一个流程，几秒后弹出带分类按钮的记账结果通知，长按选分类，体验分类建议（`Simulation`）。
/// 一键清除在按钮弹出的小菜单里再点一下，删掉模拟卡、它的流水和学到的「模拟·」商户。页面上不写说明文字
struct SimulationView: View {
    @Environment(LedgerStore.self) private var store
    @State private var count = 0
    @State private var lastText: String?
    @State private var busy = false
    @State private var errorText: String?
    /// 开着演示数据时：记在演示的中行卡上，商户是演示数据里的店
    private let demo = DemoMode.language

    var body: some View {
        List {
            Section {
                ForEach(SimulatedSpend.allCases) { spend in
                    Button { Task { await simulate(spend) } } label: {
                        // 演示账本（ADR 0025）里是演示数据的店，按演示的语言
                        LabeledContent(spend.title, value: (demo.map { spend.merchant(in: $0) } ?? spend.merchant) ?? "")
                    }
                }
            }
            if let lastText {
                Section { Text(lastText) }
            }
            Section {
                LabeledContent("模拟了", value: "\(count) 笔")
                Menu {
                    Button(role: .destructive) { Task { await clear() } } label: {
                        Label(demo == nil ? "删掉模拟卡和它的全部流水" : "删掉模拟的流水", systemImage: "trash")
                    }
                } label: {
                    Label("一键清除", systemImage: "trash")
                }
                .disabled(count == 0)
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
            lastText = item?.result == .recorded ? "\(spend.title)：\(amount)" : "\(spend.title)：\(result.summary)"
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
            lastText = "清除了 \(removed) 笔"
            count = 0
            errorText = nil
        } catch {
            errorText = "清除失败：\(error.localizedDescription)"
        }
    }
}
