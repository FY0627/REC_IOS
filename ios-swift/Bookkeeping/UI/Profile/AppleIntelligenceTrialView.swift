import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 在这台手机上试苹果智能读银行通知准不准：不入账，不改任何数据，还没有接到自动记账里。
/// 样本是 `NoticeSamples`，每条让规则和模型各读一遍，和答案逐项比较。
struct AppleIntelligenceTrialView: View {
    @State private var status = AppleIntelligenceReader.status()
    @State private var rows: [NoticeTrialRow] = []
    @State private var running = false
    @State private var run: Task<Void, Never>?
    @State private var copied = false
    @State private var pasted = ""
    @State private var readingPasted = false
    @State private var pastedResult: PastedResult?

    private struct PastedResult {
        var rules: NoticeReading
        var model: NoticeReading?
        var failure: String?
    }

    private var problems: [NoticeTrialRow] {
        rows.filter { $0.failure != nil || !$0.modelDifferences.isEmpty || !$0.invented.isEmpty }
    }

    var body: some View {
        List {
            statusSection
            runSection
            if !running, !rows.isEmpty {
                scoreSection
                if !problems.isEmpty { problemSection }
            }
            pasteSection
        }
        .navigationTitle("苹果智能试读")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = AppleIntelligenceReader.status() }
        .onDisappear {
            run?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var statusSection: some View {
        Section("这台手机") {
            LabeledContent("模型", value: status.detail)
            LabeledContent("系统", value: "iOS \(UIDevice.current.systemVersion)")
            if let contextSize = status.contextSize {
                LabeledContent("上下文", value: "\(contextSize)")
            }
            ForEach(status.languages, id: \.name) { language in
                LabeledContent(language.name, value: language.supported ? "支持" : "不支持")
            }
        }
    }

    private var runSection: some View {
        Section {
            if running {
                ProgressView(value: Double(rows.count), total: Double(NoticeSamples.all.count)) {
                    Text("已读 \(rows.count) / \(NoticeSamples.all.count) 条")
                }
            } else {
                Button("读取 \(NoticeSamples.all.count) 条样本", action: startRun)
                    .disabled(!status.available)
            }
        } header: {
            Text("样本对比")
        } footer: {
            Text("读取时不要锁屏或切到别的 App。只比较，不入账。")
        }
    }

    private var scoreSection: some View {
        Section {
            LabeledContent("读取失败", value: "\(rows.filter { $0.model == nil }.count) 条")
            LabeledContent("金额或尾号不在原文里", value: "\(rows.filter { !$0.invented.isEmpty }.count) 条")
            if let timing = NoticeTrial.timing(rows) {
                LabeledContent("平均用时", value: String(format: "%.1f 秒", timing.average))
                LabeledContent("最慢", value: String(format: "%.1f 秒", timing.slowest))
            }
            ForEach(NoticeTrial.scores(rows)) { score in
                LabeledContent(score.field.rawValue) {
                    Text("规则 \(score.rulesRight)/\(score.rulesTotal) · 智能 \(score.modelRight)/\(score.modelTotal)")
                        .monospacedDigit()
                }
            }
            Button {
                UIPasteboard.general.string = NoticeTrial.report(rows, header: status.summary + ["系统：iOS \(UIDevice.current.systemVersion)", "版本：\(BuildInfo.summary)"])
                copied = true
            } label: {
                Label(copied ? "已复制" : "复制结果", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        } header: {
            Text("结果")
        } footer: {
            Text("读取失败的样本不算进智能那一列的总数。")
        }
    }

    private var problemSection: some View {
        Section("读错的样本") {
            ForEach(problems) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(row.id) \(row.text)")
                        .font(.subheadline)
                        .lineLimit(3)
                    if let failure = row.failure {
                        Text("读取失败：\(failure)").foregroundStyle(.orange)
                    }
                    ForEach(row.modelDifferences) { difference in
                        Text("\(difference.field.rawValue)：应为 \(difference.expected)，读成 \(difference.actual)")
                            .foregroundStyle(.red)
                    }
                    if !row.invented.isEmpty {
                        Text("不在原文里：" + row.invented.map(\.rawValue).joined(separator: "、"))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var pasteSection: some View {
        Section {
            TextField("粘贴一条通知", text: $pasted, axis: .vertical)
                .lineLimit(3...8)
            Button(readingPasted ? "读取中…" : "读取", action: readPasted)
                .disabled(readingPasted || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let result = pastedResult {
                if let failure = result.failure {
                    Text("苹果智能读取失败：\(failure)").foregroundStyle(.orange)
                }
                ForEach(NoticeField.allCases) { field in
                    LabeledContent(field.rawValue) {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let model = result.model { Text("智能：\(model.text(of: field))") }
                            Text("规则：\(result.rules.text(of: field))")
                        }
                    }
                }
            }
        } header: {
            Text("自己试一条")
        } footer: {
            Text("只在这台手机上读取，不保存，不入账。")
        }
    }

    private func startRun() {
        rows = []
        copied = false
        running = true
        // 锁屏后 App 进后台，模型可能被限速，比出来的就不是模型本身的准确率了
        UIApplication.shared.isIdleTimerDisabled = true
        run = Task {
            for (index, sample) in NoticeSamples.all.enumerated() where !Task.isCancelled {
                rows.append(await AppleIntelligenceReader.trial(id: index + 1, sample: sample))
            }
            UIApplication.shared.isIdleTimerDisabled = false
            running = false
        }
    }

    private func readPasted() {
        let text = pasted
        readingPasted = true
        pastedResult = nil
        Task {
            let rules = await Task.detached(priority: .userInitiated) {
                NoticeReading(rules: text, referenceDate: Date(), calendar: .current)
            }.value
            let result = status.available ? await AppleIntelligenceReader.read(text) : (nil, status.detail)
            pastedResult = PastedResult(rules: rules, model: result.0, failure: result.1)
            readingPasted = false
        }
    }
}
