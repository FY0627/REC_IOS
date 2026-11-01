import SwiftUI
import UIKit
import BKBackend

/// 「用快捷指令更新汇率」：添加共享的快捷指令「导入汇率」（获取 URL 内容 → App 动作「导入汇率」），
/// 再建一个打开 App 时运行它的自动化。联网的是快捷指令，App 自己不联网。
///
/// 共享的快捷指令按 App 标识找「导入汇率」动作。别人用自己的 Apple ID 侧载时标识后面是他的签名团队，
/// 链接里的动作对不上：这时不给链接，改成自己搭（复制汇率地址，两个动作）。
struct ExchangeRateGuideView: View {
    /// 共享的快捷指令「导入汇率」：下载 `ExchangeRateFeed.url` 的汇率，交给 App 动作「导入汇率」，用户不用自己搭
    static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/22f748b09286411b98d5af7ac8b5cff7")!
    /// 做这份共享链接时装的 App 的标识（包名 + 签名团队后缀）；换签名账号、改包名后要重新做链接，再改这两处
    static let shortcutBundleID = "com.example.bookkeepingApp.swift.99VRUR76S7"

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    /// 装的就是做共享链接的那个 App：链接里的「导入汇率」认得它
    private var sharedShortcutWorks: Bool { Bundle.main.bundleIdentifier == Self.shortcutBundleID }
    private var steps: [LocalizedStringKey] { sharedShortcutWorks ? Self.sharedSteps : Self.manualSteps }

    var body: some View {
        List {
            // 和系统设置一样的普通行，不用大按钮
            Section {
                if sharedShortcutWorks {
                    Button("添加快捷指令「导入汇率」", systemImage: "plus.square.on.square") { leave(to: Self.shortcutURL) }
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

            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            } header: {
                Text("\(steps.count) 步完成")
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

    static let sharedSteps: [LocalizedStringKey] = [
        "点上面 **添加快捷指令**，在打开的页面点 **添加快捷指令**。它会下载最新汇率，交给 REC 导入。",
        "点 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **App** → **REC** → 勾选 **已打开**，选 **立即运行**，点 **下一步**。",
        "在列表里选刚添加的 **导入汇率**。以后每次打开 App，汇率都会自动更新。",
    ]

    /// 自己侧载的 App 用不了共享链接：自己搭这两个动作
    static let manualSteps: [LocalizedStringKey] = [
        "点上面 **复制汇率地址**，再点 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**。",
        "选 **App** → **REC** → 勾选 **已打开**，选 **立即运行**，点 **下一步**。",
        "点 **新建空白自动化** → **添加操作**，搜索 **获取 URL 内容** 并添加，把地址粘贴进去。",
        "再添加 **导入汇率**，确认 **汇率数据** 显示为 **URL 的内容**（没有就点它选上），点 **完成**。",
    ]
}
