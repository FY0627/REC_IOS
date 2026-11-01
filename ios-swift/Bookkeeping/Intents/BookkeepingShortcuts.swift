import AppIntents

/// 让「记录银行动账通知」「导入汇率」安装后即出现在「快捷指令」App 的 App 动作列表中，
/// 设置自动化时可以直接搜索到，无需用户先运行一次 App 动作。
struct BookkeepingShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordBankMessageIntent(),
            phrases: [
                "用\(.applicationName)记录银行通知",
                "在\(.applicationName)记录动账通知",
            ],
            shortTitle: "记录银行通知",
            systemImageName: "creditcard.and.123"
        )
        AppShortcut(
            intent: ImportExchangeRatesIntent(),
            phrases: [
                "用\(.applicationName)导入汇率",
            ],
            shortTitle: "导入汇率",
            systemImageName: "arrow.left.arrow.right.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
