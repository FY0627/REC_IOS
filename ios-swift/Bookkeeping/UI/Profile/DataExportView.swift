import SwiftUI
import BKBackend

/// 导出数据（「我的 › 隐私与数据」，ADR 0019）：打开就把全部数据打成一个 zip（`DataExport`）——每种数据一个 CSV，
/// 加一份能导回来的数据库副本——点一下用系统的分享菜单存到「文件」或发出去。卡面图片不导出。文件只在这台手机上生成，App 不联网
struct DataExportView: View {
    @Environment(LedgerStore.self) private var store
    @State private var file: URL?
    @State private var summary: DataExportSummary?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if let file, let summary {
                    ShareLink(item: file) {
                        Label("导出全部数据", systemImage: "square.and.arrow.up")
                    }
                    LabeledContent("流水", value: "\(summary.records) 笔")
                    LabeledContent("账户", value: "\(summary.accounts) 个")
                } else if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在生成…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("一个 zip 压缩包：每种数据一个 CSV 文件（\(summary.map { $0.files.map { $0.replacingOccurrences(of: ".csv", with: "") }.joined(separator: "、") } ?? "流水、账户、余额、分类等")），可以用 Numbers 或 Excel 打开；还有一份数据库副本，在「导入数据」里选这个 zip 就能导回来。卡面图片不导出。\n\n里面有完整卡号（填过的话）和收到的通知原文，分享前想清楚发给谁。")
            }
        }
        .navigationTitle("导出数据")
        .navigationBarTitleDisplayMode(.inline)
        .task { await export() }
    }

    private func export() async {
        do {
            let result = try await store.exportData()
            summary = result.summary
            file = result.url
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }
}
