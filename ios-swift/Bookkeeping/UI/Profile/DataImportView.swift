import SwiftUI
import UniformTypeIdentifiers
import BKBackend

/// 导入数据（「我的 › 隐私与数据」，ADR 0019）：选一个「导出数据」得到的 zip，先看里面有什么，勾选导入哪几样
/// （账本、卡面图片、设置，默认全选），账本再选增量或覆盖（`BackupImport`）。
/// 覆盖要在按钮弹出的小菜单里再点一下。导入账本前自动把现在的数据存一份，可以撤销上次导入
struct DataImportView: View {
    @Environment(LedgerStore.self) private var store
    @State private var picking = false
    @State private var archive: Data?
    @State private var fileName = ""
    @State private var info: BackupInfo?
    @State private var includeLedger = true
    @State private var includeFaces = true
    @State private var includeSettings = true
    @State private var result: ImportSummary?
    @State private var restored: [LocalizedStringKey] = []
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
            if let info, archive != nil, result == nil, restored.isEmpty {
                Section("「\(fileName)」里有") {
                    LabeledContent("流水", value: L("\(info.records) 笔"))
                    LabeledContent("账户", value: L("\(info.accounts) 个"))
                    if let last = info.lastRecordAt {
                        LabeledContent("最晚一笔", value: Fmt.dateTime(last))
                    }
                }
                if info.faceImages > 0 || info.hasSettings {
                    Section("导入") {
                        Toggle(isOn: $includeLedger) { Label("账本", systemImage: "list.bullet.rectangle") }
                        if info.faceImages > 0 {
                            Toggle(isOn: $includeFaces) { Label(L("卡面图片 \(info.faceImages) 张"), systemImage: "photo") }
                        }
                        if info.hasSettings {
                            Toggle(isOn: $includeSettings) { Label("设置", systemImage: "gearshape") }
                        }
                    }
                }
                Section {
                    if includeLedger {
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
                    } else {
                        Button { Task { await run(nil) } } label: {
                            Label("导入", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!faces(info) && !settings(info))
                    }
                }
            }
            if !restored.isEmpty {
                Section("导入完了") {
                    ForEach(restored.indices, id: \.self) { i in
                        Label(restored[i], systemImage: "checkmark")
                    }
                }
            }
            if let result {
                Section(restored.isEmpty ? LocalizedStringKey("导入完了") : "账本") {
                    if result.mode == .merge {
                        LabeledContent("加了流水", value: L("\(result.records) 笔"))
                        LabeledContent("本来就有的流水", value: L("\(result.existingRecords) 笔"))
                        LabeledContent("加了账户", value: L("\(result.accounts) 个"))
                        LabeledContent("对上了已有的账户", value: L("\(result.existingAccounts) 个"))
                        LabeledContent("加了分类", value: L("\(result.categories) 个"))
                    } else {
                        LabeledContent("流水", value: L("\(result.records) 笔"))
                        LabeledContent("账户", value: L("\(result.accounts) 个"))
                        LabeledContent("分类", value: L("\(result.categories) 个"))
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
            includeLedger = true
            includeFaces = true
            includeSettings = true
            result = nil
            restored = []
            undone = false
            errorText = nil
        } catch {
            archive = nil
            info = nil
            errorText = message(error)
        }
    }

    private func faces(_ info: BackupInfo) -> Bool { includeFaces && info.faceImages > 0 }
    private func settings(_ info: BackupInfo) -> Bool { includeSettings && info.hasSettings }

    private func run(_ mode: ImportMode?) async {
        guard let archive, let info else { return }
        busy = true
        defer { busy = false }
        do {
            let faces = faces(info), settings = settings(info)
            result = try await store.importBackup(archive: archive, ledger: mode, faceImages: faces, settings: settings)
            restored = []
            if faces { restored.append("卡面图片") }
            if settings { restored.append("设置") }
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
            restored = []
            undone = true
            canUndo = store.canUndoImport
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? BackendError {
        case .backupUnreadable?: L("读不了这个文件")
        case .backupTooNew?: L("这个文件来自更新版本的 REC，先更新 App")
        default: L("导入失败：\(error.localizedDescription)")
        }
    }
}
