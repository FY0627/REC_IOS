import SwiftUI
import UniformTypeIdentifiers
import BKBackend

/// 导入数据（「我的 › 隐私与数据」，ADR 0019）：选一个「导出数据」得到的 zip，先看里面有什么，再选增量或覆盖（`BackupImport`）。
/// 覆盖要在按钮弹出的小菜单里再点一下。导入前自动把现在的数据存一份，可以撤销上次导入
struct DataImportView: View {
    @Environment(LedgerStore.self) private var store
    @State private var picking = false
    @State private var archive: Data?
    @State private var fileName = ""
    @State private var info: BackupInfo?
    @State private var result: ImportSummary?
    @State private var undone = false
    @State private var canUndo = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Button { picking = true } label: {
                    Label(archive == nil ? "选择文件" : "换一个文件", systemImage: "doc.zipper")
                }
            }
            if let info, archive != nil, result == nil {
                Section("「\(fileName)」里有") {
                    LabeledContent("流水", value: "\(info.records) 笔")
                    LabeledContent("账户", value: "\(info.accounts) 个")
                    if let last = info.lastRecordAt {
                        LabeledContent("最晚一笔", value: Fmt.dateTime(last))
                    }
                }
                Section {
                    Button { Task { await run(.merge) } } label: {
                        Label("增量导入", systemImage: "plus.square.on.square")
                    }
                    Menu {
                        Button(role: .destructive) { Task { await run(.replace) } } label: {
                            Label("删掉现在的数据，全部换成导入的", systemImage: "trash")
                        }
                    } label: {
                        Label("覆盖导入", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            if let result {
                Section("导入完了") {
                    if result.mode == .merge {
                        LabeledContent("加了流水", value: "\(result.records) 笔")
                        LabeledContent("本来就有的流水", value: "\(result.existingRecords) 笔")
                        LabeledContent("加了账户", value: "\(result.accounts) 个")
                        LabeledContent("对上了已有的账户", value: "\(result.existingAccounts) 个")
                        LabeledContent("加了分类", value: "\(result.categories) 个")
                    } else {
                        LabeledContent("流水", value: "\(result.records) 笔")
                        LabeledContent("账户", value: "\(result.accounts) 个")
                        LabeledContent("分类", value: "\(result.categories) 个")
                    }
                }
            }
            if undone {
                Section { Text("已经换回导入前的数据。") }
            }
            if canUndo {
                Section {
                    Menu {
                        Button(role: .destructive) { Task { await undo() } } label: {
                            Label("换回导入前的数据", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("撤销上次导入", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            if busy {
                ProgressView()
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .disabled(busy)
        .navigationTitle("导入数据")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { picked in
            guard case .success(let url) = picked else { return }
            Task { await load(url) }
        }
        .task { canUndo = store.canUndoImport }
    }

    /// 读文件放在后台：文件可能有几 MB
    private func load(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            info = try await store.backupInfo(archive: data)
            archive = data
            fileName = url.lastPathComponent
            result = nil
            undone = false
            errorText = nil
        } catch {
            archive = nil
            info = nil
            errorText = message(error)
        }
    }

    private func run(_ mode: ImportMode) async {
        guard let archive else { return }
        busy = true
        defer { busy = false }
        do {
            result = try await store.importBackup(archive: archive, mode: mode)
            canUndo = store.canUndoImport
            undone = false
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func undo() async {
        busy = true
        defer { busy = false }
        do {
            try await store.undoImport()
            result = nil
            undone = true
            canUndo = store.canUndoImport
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? BackendError {
        case .backupUnreadable?: "读不了这个文件"
        case .backupTooNew?: "这个文件来自更新版本的 REC，先更新 App"
        default: "导入失败：\(error.localizedDescription)"
        }
    }
}
