import SwiftUI

/// 导出数据（「我的 › 隐私与数据」）：打开就把全部流水写成一个 CSV 文件，点一下用系统的分享菜单存到「文件」或发出去。
/// 文件只在这台手机上生成，App 不联网
struct DataExportView: View {
    @Environment(LedgerStore.self) private var store
    @State private var file: URL?
    @State private var count = 0
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                if let file {
                    ShareLink(item: file) {
                        Label("导出流水（\(count) 笔）", systemImage: "square.and.arrow.up")
                    }
                } else if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在生成…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("每笔流水一行：时间、类型、分类、金额、币种、账户、交易对方、备注等，流入为正、流出为负。CSV 文件可以用 Numbers 或 Excel 打开。文件只在这台手机上生成，分享给谁由你决定。")
            }
        }
        .navigationTitle("导出数据")
        .navigationBarTitleDisplayMode(.inline)
        .task { await export() }
    }

    private func export() async {
        do {
            let result = try await store.exportRecords()
            count = result.count
            file = result.url
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }
}
