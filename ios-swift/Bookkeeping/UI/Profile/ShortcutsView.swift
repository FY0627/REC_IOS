import SwiftUI
import BKBackend

/// 「我的 › 快捷指令」：App 用到的快捷指令都在这一页，一个快捷指令一组——自动记账、截图记账、更新汇率。
/// 跳过了新手引导、后来想加的，在这里一次找全（以前分在「设置自动记账」「设置截图记账」「记账 › 汇率」三个地方）。
///
/// TestFlight / App Store 装的：每组一个「添加快捷指令」，添加后要做的一句话写在组下面；
/// 还要自己建自动化的（iOS 26 的自动记账）和自己侧载的（用不了共享链接），点「设置步骤」进原来的分步页面。
/// 能看出在工作的写上状态：自动记账收到过银行通知、汇率导入过。
struct ShortcutsView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @Environment(\.openURL) private var openURL

    private var shared: Bool { SharedShortcuts.available }
    /// iOS 27 的「自动记账」自带触发条件，添加后只要选银行 App
    private var bankNeedsSteps: Bool {
        if #available(iOS 27, *) { return !shared }
        return true
    }

    var body: some View {
        List {
            Section {
                if shared {
                    addButton(SharedShortcuts.bankMessage)
                }
                if bankNeedsSteps {
                    stepsLink(.autoSetup)
                }
                if store.automationVerified {
                    working("已收到过银行通知")
                }
            } header: {
                Text("自动记账")
            } footer: {
                if bankNeedsSteps {
                    Text("只需设置一次，之后添加的卡不用再设置。")
                } else {
                    Text(AutoSetupSections.sharedLine)
                }
            }

            Section {
                if shared {
                    addButton(SharedShortcuts.paymentScreenshot)
                } else {
                    stepsLink(.screenshotSetup)
                }
            } header: {
                Text("截图记账")
            } footer: {
                if shared { Text(ScreenshotSetupSections.sharedLine) }
            }

            Section {
                if shared {
                    Button("添加快捷指令", systemImage: "plus.square.on.square") {
                        Task {
                            // 开着导入汇率通知：离开 App 前先要通知权限（和原来的设置页一样）
                            if ImportExchangeRatesIntent.notifies { _ = await IngestNotifier.requestAuthorization() }
                            openURL(SharedShortcuts.exchangeRates)
                        }
                    }
                } else {
                    stepsLink(.exchangeRates)
                }
                LabeledContent("汇率", value: rateStatus)
            } header: {
                Text("更新汇率")
            } footer: {
                if shared { Text(ExchangeRateSetupSections.sharedLine) }
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addButton(_ url: URL) -> some View {
        Button("添加快捷指令", systemImage: "plus.square.on.square") { openURL(url) }
    }

    private func stepsLink(_ route: ProfileRoute) -> some View {
        NavigationLink(value: route) {
            Label("设置步骤", systemImage: "list.number")
        }
    }

    private func working(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var rateStatus: String {
        rates.rates.map { L("更新于 \(Fmt.dateTime($0.updatedAt))") } ?? L("尚未导入")
    }
}
