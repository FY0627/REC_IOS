import SwiftUI
import UIKit
import BKBackend

/// 导出数据（「我的 › 数据」，ADR 0019）：先勾选导出哪几样——账本（能导回来的数据库副本）、表格（每种数据一个 CSV）、
/// 卡面图片、「我的」里的设置，默认全选——再点「导出」打成一个 zip（`DataExport`），用系统的分享菜单存到「文件」或发出去。
/// 用不着的不打包，文件小、传得快（比如换手机只要账本和图片，想在表格里看只要表格）。
/// 勾选旁边写着有多少、大概多大。文件只在这台手机上生成，App 不联网
struct DataExportView: View {
    @Environment(LedgerStore.self) private var store
    @State private var choice = LedgerStore.ExportChoice()
    @State private var preview: LedgerStore.ExportPreview?
    /// 按现在的勾选导出的文件；改了勾选就作废
    @State private var file: URL?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $choice.ledger) {
                    row("账本（导入用）", detail: ledgerDetail, systemImage: "list.bullet.rectangle")
                }
                Toggle(isOn: $choice.tables) {
                    row("表格（CSV）", detail: nil, systemImage: "tablecells")
                }
                if let preview, preview.faceImages > 0 {
                    Toggle(isOn: $choice.faceImages) {
                        row("卡面图片", detail: L("\(preview.faceImages) 张 · \(size(preview.faceImageBytes))"), systemImage: "photo")
                    }
                }
                Toggle(isOn: $choice.settings) {
                    row("设置", detail: nil, systemImage: "gearshape")
                }
            } header: {
                Text("导出内容")
            }

            Section {
                Button {
                    Task { await export() }
                } label: {
                    HStack {
                        Label("导出", systemImage: "square.and.arrow.up")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(choice.isEmpty || busy)
                // 分享菜单关掉了还想再存一份：不用重新打包
                if let file {
                    ShareLink(item: file) {
                        Label(file.lastPathComponent, systemImage: "doc.zipper")
                    }
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("导出数据")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let preview = await store.exportPreview()
            self.preview = preview
            // 没有卡面图片时这一项不显示，也不算勾上
            if preview.faceImages == 0 { choice.faceImages = false }
        }
        .onChange(of: choice) { file = nil }
    }

    private func row(_ title: LocalizedStringKey, detail: String?, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private var ledgerDetail: String? {
        guard let preview else { return nil }
        return L("\(preview.records) 笔流水 · \(preview.accounts) 个账户 · \(size(preview.databaseBytes))")
    }

    private func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(AppLanguage.locale))
    }

    private func export() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await store.exportData(choice)
            file = result.url
            errorText = nil
            ShareSheet.present(result.url)
        } catch {
            errorText = L("导出失败：\(error.localizedDescription)")
        }
    }
}

/// 打包好马上弹出系统的分享菜单（`ShareLink` 只能等用户点）
@MainActor
enum ShareSheet {
    static func present(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
}
