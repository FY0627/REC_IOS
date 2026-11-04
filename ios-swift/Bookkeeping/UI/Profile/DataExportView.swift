import SwiftUI
import BKBackend

/// 导出数据（「我的 › 隐私与数据」）：打开就把全部数据写成一组 CSV（流水、账户、余额、分类、学到的分类、识别模板、汇率、待处理、
/// 原始通知、通知里的余额，见 `DataExport`），打成一个 zip，点一下用系统的分享菜单存到「文件」或发出去。
/// 卡面图片不导出。文件只在这台手机上生成，App 不联网
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
                Text("一个 zip 压缩包，里面每种数据一个 CSV 文件：\(summary.map { $0.files.map { $0.replacingOccurrences(of: ".csv", with: "") }.joined(separator: "、") } ?? "流水、账户、余额、分类等")。卡面图片不导出。可以用 Numbers 或 Excel 打开。\n\n里面有完整卡号（填过的话）和收到的通知原文，分享前想清楚发给谁。")
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

/// 把一个文件夹打成 zip：系统按「上传」方式读取文件夹时会给出它的 zip（iOS 自带，不用第三方库）。
/// 给出的 zip 只在读取的闭包里有效，复制出来
enum ZipFolder {
    static func make(_ folder: URL, at destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }
}
