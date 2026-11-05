import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 「我的」：系统设置风格的分组列表，二级页面用导航推入（`ProfileRoute`）。推进去时标签栏滑出、回来时滑入，
/// 和资产页打开卡片详情一样：显隐放在整个导航栈外面，在动画里切换。
///
/// 标签栏的状态放在外面这一层，列表和导航栈在 `ProfileList` 里：切换标签栏的动画只改外面这层，不重新计算列表。
struct ProfileView: View {
    @State private var path: [ProfileRoute] = []
    /// 推进了二级页面：标签栏藏起来。和 `path` 分开、在动画里改，标签栏才会滑出 / 滑入，不是一下子没了
    @State private var subpageOpen = false

    var body: some View {
        ProfileList(path: $path)
            .toolbarVisibility(subpageOpen ? .hidden : .visible, for: .tabBar)
            .onChange(of: path.isEmpty) { _, empty in
                withAnimation(.smooth(duration: 0.35)) { subpageOpen = !empty }
            }
    }
}

/// 「我的」推进去的二级页面
enum ProfileRoute: Hashable {
    case primaryCurrency, exchangeRates, categories, autoSetup, automationStatus, categoryCheckup, templates, help, dataExport, dataImport, simulation, performance
}

/// 「我的」的列表和导航栈。顶部一行和首页、资产页一样高、一样的位置；列表滚到它下面时垫一层磨砂背景（和首页一样）。
/// 列表和首页、统计是同一种，顶部一行也一样高，第一个白框和灰字自然和它们一样，不用再算。
private struct ProfileList: View {
    @Binding var path: [ProfileRoute]

    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(AppearanceMode.iconKey) private var appIcon = AppearanceMode.system.rawValue
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.blue.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @AppStorage(ImportExchangeRatesIntent.notifyKey) private var notifyRates = true
    @State private var retention = 30
    @State private var notifyDenied = false
    @State private var scrolledUnderBar = false
    @State private var choosingTheme = false
    /// 导航栈外面的安全区：状态栏的高度
    @State private var stackSafeTop: CGFloat = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("显示") {
                    // 菜单按钮右边的文字（选中的项）换了主题色不会马上重画，按主题色重建这一行
                    Picker(selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                    .id("appearance-\(themeColor)")
                    Picker(selection: $appIcon) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("图标", systemImage: "app")
                    }
                    .id("icon-\(themeColor)")
                    .onChange(of: appIcon) { AppearanceMode.applyIcon() }
                    Button { choosingTheme = true } label: {
                        LabeledContent {
                            Text(ThemeColor.title(stored: themeColor)).foregroundStyle(.tint)
                        } label: {
                            Label {
                                Text("主题色").foregroundStyle(Color.primary)
                            } icon: {
                                Image(systemName: "paintpalette")
                            }
                        }
                        .background(UndimmedList())
                    }
                }

                Section("币种与汇率") {
                    NavigationLink(value: ProfileRoute.primaryCurrency) {
                        LabeledContent {
                            Text(CurrencyCode(primaryCurrency).chineseName)
                        } label: {
                            Label("主要币种", systemImage: "dollarsign.circle")
                        }
                    }
                    NavigationLink(value: ProfileRoute.exchangeRates) {
                        Label("用快捷指令更新汇率", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section("记账") {
                    NavigationLink(value: ProfileRoute.categories) {
                        Label("分类", systemImage: "square.grid.2x2")
                    }
                }

                Section("自动记账") {
                    NavigationLink(value: ProfileRoute.autoSetup) {
                        Label("设置自动记账", systemImage: "bolt.badge.automatic")
                    }
                    NavigationLink(value: ProfileRoute.automationStatus) {
                        Label("自动记账状态", systemImage: "checkmark.seal")
                    }
                    NavigationLink(value: ProfileRoute.templates) {
                        Label("识别模板", systemImage: "text.viewfinder")
                    }
                    NavigationLink(value: ProfileRoute.help) {
                        Label("使用说明", systemImage: "questionmark.circle")
                    }
                }

                Section("通知") {
                    Picker(selection: $notifyMode) {
                        ForEach(IngestNotifier.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("记账结果", systemImage: "bell.badge")
                    }
                    .id("notify-\(themeColor)")
                    .onChange(of: notifyMode) { _, mode in
                        guard mode != IngestNotifier.Mode.off.rawValue else { return }
                        askPermission { notifyMode = IngestNotifier.Mode.off.rawValue }
                    }
                    Toggle(isOn: $notifyRates) {
                        Label("导入汇率通知", systemImage: "arrow.left.arrow.right.circle")
                    }
                    .onChange(of: notifyRates) { _, on in
                        guard on else { return }
                        askPermission { notifyRates = false }
                    }
                }

                Section("隐私与数据") {
                    Picker(selection: $retention) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                    } label: {
                        Label("原始通知保留", systemImage: "clock.arrow.circlepath")
                    }
                    .id("retention-\(themeColor)")
                    NavigationLink(value: ProfileRoute.dataExport) {
                        Label("导出数据", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(value: ProfileRoute.dataImport) {
                        Label("导入数据", systemImage: "square.and.arrow.down")
                    }
                }

                Section("开发与调试") {
                    NavigationLink(value: ProfileRoute.simulation) {
                        Label("模拟消费", systemImage: "cart.badge.plus")
                    }
                    NavigationLink(value: ProfileRoute.performance) {
                        Label("性能开关与调试指标", systemImage: "speedometer")
                    }
                }

                Section("关于") {
                    LabeledContent("REC", value: "iOS 原生 Swift 版")
                    LabeledContent("版本", value: BuildInfo.summary)
                        .font(.subheadline.monospaced())
                    LabeledContent("汇率", value: rateStatus)
                    // 汇率数据源要求注明来源并链接到官网
                    Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                }
            }
            .listStyle(.insetGrouped)
            // 这里的 themeColor 比 App 那层的 .tint 先变：按主题色重建的菜单行如果只靠外面的 .tint，
            // 重建时拿到的还是上一个颜色（比现在选的晚一个）。用同一个值，重建时就是新颜色
            .tint(ThemeColor.color(stored: themeColor))
            .sheet(isPresented: $choosingTheme) { ThemeColorSheet(selection: $themeColor) }
            .alert("没有通知权限", isPresented: $notifyDenied) {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("在系统设置里允许 REC 发送通知。")
            }
            .trackingScrollUnderTopBar($scrolledUnderBar)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            // 系统导航栏一直留着，里面什么也不放（标题留给二级页面的返回按钮，这里换成空的）。
            // 不能藏：藏起来的话从二级页面返回时系统要把导航栏收走，顶上的东西会往中间收、再往上消失
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                    .sharedBackgroundVisibility(.hidden)
            }
            // 系统的大标题比资产页的标题行低，自己放一行
            .safeAreaBar(edge: .top) {
                TitleBar(title: "我的")
                    .frame(height: GlassControls.size)
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, stackSafeTop + 2)
                    .padding(.bottom, AppLayout.topBarBottom)
                    .background { TopBarBackdrop(visible: scrolledUnderBar) }
            }
            // 不让出导航栏的位置，从屏幕顶端排：列表离状态栏的距离和首页、统计一样，和导航栏多高无关。
            // 缩短顶部一行做不到：缩到 0 时列表还在导航栏下面，再缩也不会往上走
            .ignoresSafeArea(.container, edges: .top)
            .navigationDestination(for: ProfileRoute.self) { destination($0) }
            .task { retention = await store.retentionDays() }
            .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { stackSafeTop = $0 }
    }

    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .primaryCurrency: CurrencyPicker(title: "主要币种", selection: primaryCurrencyList, multiple: false)
        case .exchangeRates: ExchangeRateGuideView()
        case .categories: CategoryManagerView()
        case .autoSetup: AutoSetupGuideView()
        case .automationStatus: AutomationStatusView()
        case .categoryCheckup: CategoryCheckupView()
        case .templates: TemplateListView()
        case .help: HelpView()
        case .dataExport: DataExportView()
        case .dataImport: DataImportView()
        case .simulation: SimulationView()
        case .performance: PerformanceSettingsView()
        }
    }

    /// 打开一种通知时要通知权限；被拒绝就关回去，提示去系统设置
    private func askPermission(revert: @escaping () -> Void) {
        Task {
            if !(await IngestNotifier.requestAuthorization()) {
                revert()
                notifyDenied = true
            }
        }
    }

    private var rateStatus: String {
        rates.rates.map { "更新于 \(Fmt.dateTime($0.updatedAt))" } ?? "尚未导入"
    }

    /// 选币种页面用的单选列表
    private var primaryCurrencyList: Binding<[CurrencyCode]> {
        Binding { [CurrencyCode(primaryCurrency)] } set: { codes in
            if let code = codes.first { primaryCurrency = code.rawValue }
        }
    }
}

/// 打开弹窗时系统把下面的页面调暗（`tintAdjustmentMode`），菜单按钮的主题色会变成灰色。
/// 放在列表的一行里：往上找到列表，让它不跟着调暗
private struct UndimmedList: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            view?.tintAdjustmentMode = .normal
        }
    }
}

enum BuildInfo {
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BKBuildCommit"] as? String).map { String($0.prefix(7)) } ?? "本地构建"
        return "\(version) (\(build)) · \(commit)"
    }
}

/// 自动记账的可观测状态。App 无法读取快捷指令里自动化是否存在或已启用，
/// 这里只展示 App 自己能确认的事实。
struct AutomationStatusView: View {
    @Environment(LedgerStore.self) private var store
    @State private var log: [IngestLogEntry] = []

    /// 能自动记账的账户：银行卡，和选了是哪个钱包的电子钱包
    private var automated: [Account] {
        store.accounts.filter { $0.isCard || WalletDirectory.provider(of: $0) != nil }
    }

    var body: some View {
        List {
            Section("各账户最近一次成功接收") {
                if automated.isEmpty { Text("还没有添加银行卡").foregroundStyle(.secondary) }
                ForEach(automated) { account in
                    let status = store.automation[account.id]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayTitle)
                        if let last = status?.lastSuccessAt {
                            Text("已通过真实触发验证 · \(Fmt.dateTime(last))（\(status?.lastSuccessSource?.displayName ?? "")）· 累计 \(status?.receivedCount ?? 0) 次")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("待验证 · 尚未收到这个账户的自动输入").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: ProfileRoute.categoryCheckup) {
                    Label("分类建议体检", systemImage: "stethoscope")
                }
            }
            Section {
                if log.isEmpty { Text("还没有收到任何输入").foregroundStyle(.secondary) }
                ForEach(log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.detail.isEmpty ? entry.classification.displayName : entry.detail)
                            Spacer()
                            Text(entry.source.displayName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("处理于 \(Fmt.dateTime(entry.processedAt))" + (entry.receivedAt.map { " · 接收于 \(Fmt.dateTime($0))" } ?? " · 系统未提供接收时间"))
                            .font(.footnote).foregroundStyle(.secondary)
                        // 被过滤的写上原文，银行通知被误滤时能看出来
                        if entry.outcome == .filtered, let raw = entry.rawText {
                            Text(raw).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            } header: {
                Text("接收日志（最近 100 条）")
            }
        }
        .navigationTitle("自动记账状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { log = await store.ingestLog() }
        .refreshable { await store.refresh(); log = await store.ingestLog() }
    }
}

struct PerformanceSettingsView: View {
    @Bindable private var flags = PerfFlags.shared

    var body: some View {
        Form {
            Section {
                Toggle("卡片阴影", isOn: $flags.cardShadows)
                Toggle("卡面合成为位图（drawingGroup）", isOn: $flags.rasterizeCards)
                Toggle("卡面图片用遮罩裁圆角", isOn: $flags.clipCardPhotos)
                Toggle("图片卡的金额合成为位图", isOn: $flags.flattenCardAmount)
                Toggle("返回时下面的卡不回弹", isOn: $flags.gentleCardReturn)
                Toggle("返回停稳后再清空详情", isOn: $flags.lateDetailCleanup)
                Toggle("弹簧走到终点才结束", isOn: $flags.settleSprings)
                Toggle("转场保持高刷新率", isOn: $flags.holdHighRefresh)
            } header: {
                Text("单变量开关")
            }
            Section {
                Toggle("显示帧率与内存", isOn: $flags.showMetrics)
            }
            // 签名工具会改 Bundle ID；扩展的要以 App 的开头才认得是一家（ADR 0020）
            Section("通知扩展") {
                LabeledContent("App", value: Bundle.main.bundleIdentifier ?? "")
                LabeledContent("扩展", value: extensionBundleID ?? "没有")
            }
            Section {
                Button("恢复默认") { flags.resetToDefaults() }
            }
        }
        .navigationTitle("性能开关")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 装好的 App 里通知扩展的 Bundle ID；签名工具把扩展删掉了时是 nil
    private var extensionBundleID: String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("NotificationContent.appex"))?.bundleIdentifier }
    }
}
