import SwiftUI

/// 「设置截图记账」（ADR 0021）：一个快捷指令「截屏 → 记录付款截图」，设到轻点背面。付完款敲两下背面就记上。
/// iOS 不让 App 自己建快捷指令，这里只给最少的手动步骤；内测时快捷指令可以用 iCloud 链接共享，装好就能用。
/// 从相册补记在「记一笔」里，不用设置
struct ScreenshotSetupGuideView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            }
            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            } header: {
                Text("3 步完成")
            }
        }
        .navigationTitle("设置截图记账")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let steps: [LocalizedStringKey] = [
        "在快捷指令里点 **+** 新建一个快捷指令，添加 **截屏**，再添加 **记录付款截图**，截图选上一步的 **截屏**。",
        "打开 **设置 › 辅助功能 › 触控 › 轻点背面**，选 **轻点两下**，再选刚才的快捷指令。",
        "付完款停在付款成功或账单详情页，敲两下手机背面。以前的截图在 **记一笔 › 从相册选截图** 里补记。",
    ]
}
