import SwiftUI
import UIKit
import BKBackend

/// 「用快捷指令更新汇率」：添加共享的快捷指令「导入汇率」（获取 URL 内容 → App 动作「导入汇率」），
/// 再建一个打开 App 时运行它的自动化。联网的是快捷指令，App 自己不联网。
///
/// 共享的快捷指令按 App 标识找「导入汇率」动作。别人用自己的 Apple ID 侧载时标识后面是他的签名团队，
/// 链接里的动作对不上：这时不给链接，改成自己搭（复制汇率地址，两个动作）。
struct ExchangeRateGuideView: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    /// 装的是 TestFlight / App Store 的 App：链接里的「导入汇率」认得它
    private var sharedShortcutWorks: Bool { SharedShortcuts.available }

    var body: some View {
        List {
            // 和系统设置一样的普通行，不用大按钮
            Section {
                if sharedShortcutWorks {
                    Button("添加快捷指令", systemImage: "plus.square.on.square") { leave(to: SharedShortcuts.exchangeRates) }
                } else {
                    Button(copied ? "已复制汇率地址" : "复制汇率地址", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = ExchangeRateFeed.url.absoluteString
                        copied = true
                    }
                }
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://") { leave(to: url) }
                }
            }

            if !sharedShortcutWorks {
                Section {
                    ForEach(Array(Self.manualSteps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                } header: {
                    Text("\(Self.manualSteps.count) 步完成")
                }
            }
        }
        .navigationTitle("用快捷指令更新汇率")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 「我的 › 通知」里开着导入汇率通知时，离开 App 前先要通知权限
    private func leave(to url: URL) {
        Task {
            if ImportExchangeRatesIntent.notifies { _ = await IngestNotifier.requestAuthorization() }
            openURL(url)
        }
    }

    /// 自己侧载的 App 用不了共享链接：自己搭这两个动作
    static let manualSteps: [LocalizedStringKey] = [
        "点上面 **复制汇率地址**，再点 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**。",
        "选 **App** → **REC** → 勾选 **已打开**，选 **立即运行**，点 **下一步**。",
        "点 **新建空白自动化** → **添加操作**，搜索 **获取 URL 内容** 并添加，把地址粘贴进去。",
        "再添加 **导入汇率**，确认 **汇率数据** 显示为 **URL 的内容**（没有就点它选上），点 **完成**。",
    ]
}
