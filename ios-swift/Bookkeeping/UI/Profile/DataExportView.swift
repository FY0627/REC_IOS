import SwiftUI
import BKBackend

/// 导出数据（「我的 › 隐私与数据」，ADR 0019）：打开就把全部数据打成一个 zip（`DataExport`）——每种数据一个 CSV，
/// 加一份能导回来的数据库副本、卡面图片和「我的」里的设置——点一下用系统的分享菜单存到「文件」或发出去。文件只在这台手机上生成，App 不联网
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
                    LabeledContent("流水", value: L("\(summary.records) 笔"))
                    LabeledContent("账户", value: L("\(summary.accounts) 个"))
                } else if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
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
            errorText = L("导出失败：\(error.localizedDescription)")
        }
    }
}
