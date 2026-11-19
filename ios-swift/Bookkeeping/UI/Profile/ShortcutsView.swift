import SwiftUI

/// 「我的 › 快捷指令」：App 用到的快捷指令都在这一页——自动记账、截图记账、更新汇率。
/// 最上面用分段选择换着看（和记账页选支出、收入的一样），下面直接是那个快捷指令的设置，不用再点进别的页面：
/// TestFlight / App Store 装的点「添加快捷指令」导入共享的快捷指令，再加一句添加后要做的；
/// 自己侧载的用不了共享链接（链接里的动作按 App 标识找 App），直接列出手动的步骤。内容和新手引导共用（`*SetupSections`）
struct ShortcutsView: View {
    @State private var kind: Kind = .bank

    enum Kind: CaseIterable {
        case bank, screenshot, rates

        var title: LocalizedStringKey {
            switch self {
            case .bank: "自动记账"
            case .screenshot: "截图记账"
            case .rates: "更新汇率"
            }
        }
    }

    var body: some View {
        List {
            switch kind {
            case .bank: AutoSetupSections(header: picker)
            case .screenshot: ScreenshotSetupSections(header: picker)
            case .rates: ExchangeRateSetupSections(header: picker)
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 放在第一组的标题位置（和「我的 › 分类」一样）：上面贴着导航栏，下面和设置隔开固定的一段。
    /// 单独占一行或一个空分组时，上面或下面会多出一大段
    private var picker: AnyView {
        AnyView(
            Picker("快捷指令", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .textCase(nil)
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 16)
        )
    }
}
