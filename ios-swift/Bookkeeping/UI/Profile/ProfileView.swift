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
    case shortcuts, notifications, primaryCurrency, exchangeRates, categories, autoSetup, screenshotSetup, categoryCheckup, templates, dataExport, dataImport, simulation
}

/// 「我的」的列表和导航栈。顶部一行和首页、资产页一样高、一样的位置；列表滚到它下面时垫一层磨砂背景（和首页一样）。
/// 列表和首页、统计是同一种，顶部一行也一样高，第一个白框和灰字自然和它们一样，不用再算。
private struct ProfileList: View {
    @Binding var path: [ProfileRoute]

    @Environment(LedgerStore.self) private var store
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(AppearanceMode.iconKey) private var appIcon = AppearanceMode.system.rawValue
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    /// 「开发与调试」平时藏着：连点 7 次版本号显示，再连点 7 次藏起来
    @AppStorage("showDevTools") private var showDevTools = false
    @AppStorage(LiveCategoryActivity.lastResultKey) private var liveActivityResult = ""
    @AppStorage(LiveCategoryActivity.lastTapKey) private var liveActivityTap = ""
    @AppStorage(LiveCategoryActivity.ringSecondsKey) private var ringSeconds = CategoryActivityAttributes.ContentState.ringDuration
    @AppStorage(LiveCategoryActivity.checkSecondsKey) private var checkSeconds = CategoryActivityAttributes.ContentState.checkDuration
    private let hasIsland = DynamicIsland.isPresent(model: LiveCategoryActivity.modelIdentifier)
    @State private var versionTaps = 0
    @State private var lastVersionTap = Date.distantPast
    @State private var retention = 30
    @State private var scrolledUnderBar = false
    @State private var choosingTheme = false
    @State private var showingOnboarding = false
    /// 导航栈外面的安全区：状态栏的高度
    @State private var stackSafeTop: CGFloat = 0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // 常用的在前面：自动记账、记账；外观这类设一次的放后面
                Section("自动记账") {
                    // 自动记账、截图记账、更新汇率三个快捷指令都在这一页
                    NavigationLink(value: ProfileRoute.shortcuts) {
                        Label("快捷指令", systemImage: "bolt.badge.automatic")
                    }
                    NavigationLink(value: ProfileRoute.templates) {
                        Label("识别模板", systemImage: "text.viewfinder")
                    }
                    // 记账结果、导入汇率、灵动岛，打开的下面有演示。右边不写开了哪几种：点进去就看得到
                    NavigationLink(value: ProfileRoute.notifications) {
                        Label("通知", systemImage: "bell.badge")
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
                    .id("retention-\(themeColor)-\(language)")
                }

                Section("显示") {
                    // 几种语言直接在菜单里选。「我的」不重建、原地换字（`RootView`），列表停在原处，选错了还在这一行改回来。
                    // 每种语言用它自己的文字写，看不懂现在的语言也认得出来
                    Picker(selection: Binding(get: { AppLanguage(rawValue: language) ?? .system }, set: { AppLanguage.select($0) })) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label("语言", systemImage: "globe")
                    }
                    .id("language-\(themeColor)-\(language)")
                    Picker(selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                    .id("appearance-\(themeColor)-\(language)")
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
                    // 图标直接排出来点选：只写「浅色」「深色」看不出是哪个图标
                    AppIconPicker(selection: $appIcon)
                        .onChange(of: appIcon) { AppearanceMode.applyIcon() }
                }

                Section("关于") {
                    LabeledContent("版本", value: BuildInfo.version)
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
                        // 岛上选好以后画圆圈、画对勾各用多久：在真机上调好再写死
                        if hasIsland {
                            drawTimeStepper("画圈", systemImage: "circle.dashed", value: $ringSeconds)
                            drawTimeStepper("打勾", systemImage: "checkmark", value: $checkSeconds)
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
            // 系统的大标题比资产页的标题行低，自己放一行。标题是 UIKit 画的，换语言时重建
            .safeAreaBar(edge: .top) {
                TitleBar(title: "我的")
                    .id(language)
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

    private func drawTimeStepper(_ title: LocalizedStringKey, systemImage: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: LiveCategoryActivity.drawSecondsRange, step: 0.05) {
            LabeledContent {
                Text(verbatim: String(format: "%.2f s", value.wrappedValue))
                    .monospacedDigit()
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .shortcuts: ShortcutsView()
        case .notifications: NotificationSettingsView()
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
    /// 「我的 › 关于」里显示的：版本号和构建号
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// 反馈问卷里预先填的：再加上 CI 构建的提交（自己在 Xcode 里构建的没有）
    static var summary: String {
        guard let commit = Bundle.main.infoDictionary?["BKBuildCommit"] as? String else { return version }
        return "\(version) · \(commit.prefix(7))"
    }
}
