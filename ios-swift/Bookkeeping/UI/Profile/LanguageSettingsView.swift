import SwiftUI

/// 「我的 › 语言」：跟随系统、简体中文、繁體中文、English，选中的在右边打勾（ADR 0022）。
/// 选了马上换：整个界面按新语言重建，回到「我的」（`BookkeepingApp`）
struct LanguageSettingsView: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Picker("App 语言", selection: Binding(
                get: { AppLanguage(rawValue: language) ?? .system },
                set: { AppLanguage.select($0) }
            )) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}
