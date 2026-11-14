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
    case language, primaryCurrency, exchangeRates, categories, autoSetup, screenshotSetup, categoryCheckup, templates, dataExport, dataImport, simulation, performance
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
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @AppStorage(IngestNotifier.islandKey) private var islandOn = true
    @AppStorage(LiveCategoryActivity.openingKey) private var islandOpening = LiveCategoryActivity.defaultOpening
    @AppStorage(ImportExchangeRatesIntent.notifyKey) private var notifyRates = true
    /// 「开发与调试」平时藏着：连点 7 次版本号显示，再连点 7 次藏起来
    @AppStorage("showDevTools") private var showDevTools = false
    @AppStorage(LiveCategoryActivity.lastResultKey) private var liveActivityResult = ""
    @AppStorage(LiveCategoryActivity.lastTapKey) private var liveActivityTap = ""
    private let hasIsland = DynamicIsland.isPresent(model: LiveCategoryActivity.modelIdentifier)
    @State private var versionTaps = 0
    @State private var lastVersionTap = Date.distantPast
    @State private var retention = 30
    @State private var notifyDenied = false
    @State private var scrolledUnderBar = false
    @State private var choosingTheme = false
    @State private var showingOnboarding = false
    /// 导航栈外面的安全区：状态栏的高度
    @State private var stackSafeTop: CGFloat = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // 常用的在前面：自动记账、记账；外观这类设一次的放后面
                Section("自动记账") {
                    NavigationLink(value: ProfileRoute.autoSetup) {
                        Label("设置自动记账", systemImage: "bolt.badge.automatic")
                    }
                    NavigationLink(value: ProfileRoute.screenshotSetup) {
                        Label("设置截图记账", systemImage: "camera.viewfinder")
                    }
                    NavigationLink(value: ProfileRoute.templates) {
                        Label("识别模板", systemImage: "text.viewfinder")
                    }
                    // 菜单按钮右边的文字（选中的项）换了主题色不会马上重画，按主题色重建这一行
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
                }

                Section("记账") {
                    NavigationLink(value: ProfileRoute.categories) {
                        Label("分类", systemImage: "square.grid.2x2")
                    }
                    NavigationLink(value: ProfileRoute.primaryCurrency) {
                        LabeledContent {
                            Text(CurrencyCode(primaryCurrency).localizedName)
                        } label: {
                            Label("主要币种", systemImage: "dollarsign.circle")
                        }
                    }
                    NavigationLink(value: ProfileRoute.exchangeRates) {
                        LabeledContent {
                            Text(rateStatus)
                        } label: {
                            Label("汇率", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    Toggle(isOn: $notifyRates) {
                        Label("导入汇率通知", systemImage: "arrow.left.arrow.right.circle")
                    }
                    .onChange(of: notifyRates) { _, on in
                        guard on else { return }
                        askPermission { notifyRates = false }
                    }
                }

                Section("数据") {
                    NavigationLink(value: ProfileRoute.dataExport) {
                        Label("导出数据", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(value: ProfileRoute.dataImport) {
                        Label("导入数据", systemImage: "square.and.arrow.down")
                    }
                    Picker(selection: $retention) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                    } label: {
                        Label("原始通知保留", systemImage: "clock.arrow.circlepath")
                    }
                    .id("retention-\(themeColor)")
                }

                Section("显示") {
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
                    NavigationLink(value: ProfileRoute.language) {
                        LabeledContent {
                            Text((AppLanguage(rawValue: language) ?? .system).title)
                        } label: {
                            Label("语言", systemImage: "globe")
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: BuildInfo.summary)
                        .font(.subheadline.monospaced())
                        .contentShape(Rectangle())
                        .onTapGesture(perform: tapVersion)
                    // 测试反馈问卷，机型和版本预先填好（`FeedbackForm`）
                    Link("反馈", destination: FeedbackForm.url)
                    // 汇率数据源要求注明来源并链接到官网
                    Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                }

                // 放在最后：连点版本号时它出现在下面，版本号那一行不会被挤走
                if showDevTools {
                    Section("开发与调试") {
                        NavigationLink(value: ProfileRoute.categoryCheckup) {
                            Label("分类建议体检", systemImage: "stethoscope")
                        }
                        NavigationLink(value: ProfileRoute.simulation) {
                            Label("模拟消费", systemImage: "cart.badge.plus")
                        }
                        // 官网录屏、截图用（ADR 0025）：换成一份只有账户的演示账本，关掉回到真实账本
                        Toggle(isOn: Binding(get: { store.demoActive }, set: { on in Task { await store.setDemo(on) } })) {
                            Label {
                                HStack {
                                    Text("演示数据")
                                    if store.switchingLedger { ProgressView() }
                                }
                            } icon: {
                                Image(systemName: "theatermasks")
                            }
                        }
                        .disabled(store.switchingLedger)
                        NavigationLink(value: ProfileRoute.performance) {
                            Label("性能开关与调试指标", systemImage: "speedometer")
                        }
                        // 新手引导只在第一次打开时出现，这里再看一次
                        Button {
                            showingOnboarding = true
                        } label: {
                            Label("新手引导", systemImage: "hand.wave")
                        }
                        // 灵动岛选分类上次开启的结果（ADR 0024）：后台能不能开启要在真机上看
                        LabeledContent("灵动岛", value: liveActivityResult.isEmpty ? "—" : liveActivityResult)
                        // 上次点岛上的按钮 App 这边花了多久：剩下的等待是系统叫起 App、重画岛
                        LabeledContent("灵动岛按钮", value: liveActivityTap.isEmpty ? "—" : liveActivityTap)
                        // 灵动岛的设置（ADR 0024）只放这里：关了在通知上选；新开启的岛先放提醒，过多久换成按钮。
                        // 系统自己展开几秒没有公开的数字，按真机上看到的调
                        if hasIsland {
                            Toggle(isOn: $islandOn) {
                                Label("灵动岛选分类", systemImage: "iphone.gen3")
                            }
                            .onChange(of: islandOn) { _, on in
                                // 岛上正在选的也收起，留在待分类
                                guard !on else { return }
                                Task { await LiveCategoryActivity.endAll() }
                            }
                            Stepper(value: $islandOpening, in: 1...15) {
                                LabeledContent {
                                    Text("\(islandOpening) 秒")
                                } label: {
                                    Label("灵动岛提醒时长", systemImage: "timer")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 这里的 themeColor 比 App 那层的 .tint 先变：按主题色重建的菜单行如果只靠外面的 .tint，
            // 重建时拿到的还是上一个颜色（比现在选的晚一个）。用同一个值，重建时就是新颜色
            .tint(ThemeColor.color(stored: themeColor))
            .sensoryFeedback(.success, trigger: showDevTools)
            .sheet(isPresented: $choosingTheme) { ThemeColorSheet(selection: $themeColor) }
            .fullScreenCover(isPresented: $showingOnboarding) { OnboardingView { showingOnboarding = false } }
            .alert("没有通知权限", isPresented: $notifyDenied) {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("在系统设置里允许 REC 发送通知。")
            }
            .alert("演示数据", isPresented: Binding(get: { store.demoError != nil }, set: { if !$0 { store.demoError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(store.demoError ?? "")
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
        case .language: LanguageSettingsView()
        case .primaryCurrency: CurrencyPicker(title: "主要币种", selection: primaryCurrencyList, multiple: false)
        case .exchangeRates: ExchangeRateGuideView()
        case .categories: CategoryManagerView()
        case .autoSetup: AutoSetupGuideView()
        case .screenshotSetup: ScreenshotSetupGuideView()
        case .categoryCheckup: CategoryCheckupView()
        case .templates: TemplateListView()
        case .dataExport: DataExportView()
        case .dataImport: DataImportView()
        case .simulation: SimulationView()
        case .performance: PerformanceSettingsView()
        }
    }

    /// 版本号连点 7 次（每两下间隔不超过 1.5 秒）：显示或藏起「开发与调试」
    private func tapVersion() {
        let now = Date()
        versionTaps = now.timeIntervalSince(lastVersionTap) < 1.5 ? versionTaps + 1 : 1
        lastVersionTap = now
        guard versionTaps >= 7 else { return }
        versionTaps = 0
        withAnimation { showDevTools.toggle() }
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
        rates.rates.map { L("更新于 \(Fmt.dateTime($0.updatedAt))") } ?? L("尚未导入")
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
        let commit = (info["BKBuildCommit"] as? String).map { String($0.prefix(7)) } ?? L("本地构建")
        return "\(version) (\(build)) · \(commit)"
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
                Toggle("对齐参考线", isOn: $flags.showAlignmentGuides)
            }
            // 签名工具会改 Bundle ID；扩展的要以 App 的开头才认得是一家（ADR 0020）
            Section("通知扩展") {
                LabeledContent("App", value: Bundle.main.bundleIdentifier ?? "")
                LabeledContent("扩展", value: extensionBundleID ?? L("没有"))
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
