import SwiftUI
import BKModel

/// 新手引导：第一次打开 App 时全屏出现，样子照 iOS 新机设置：每页上面大图标和大标题，中间内容，
/// 下面「继续」和一个文字按钮，左上角返回。
/// 五页：添加银行卡 → 自动记账 → 记账结果（灵动岛或通知上选分类）→ 截图记账 → 汇率。
/// 自动记账、截图记账、汇率三页和「我的」里的设置页是同一份内容。
///
/// 只给新用户：账本里没有账户、没有流水、自动化也没收到过东西。升级上来的老用户直接记成看过（`RootView`）。
/// 「我的 › 开发与调试 › 新手引导」可以再打开一次。
struct OnboardingView: View {
    static let doneKey = "onboarding.done"

    let finish: () -> Void
    @State private var path: [Step] = []

    enum Step: Hashable {
        case automation
        case results
        case screenshot
        case rates
    }

    var body: some View {
        NavigationStack(path: $path) {
            AccountsPage { path.append(.automation) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .automation:
                        SetupPage(symbol: "bolt.badge.automatic", title: "自动记账", primary: "继续") {
                            path.append(.results)
                        } content: {
                            AutoSetupSections()
                        }
                    case .results:
                        ResultsPage { path.append(.screenshot) }
                    case .screenshot:
                        SetupPage(symbol: "camera.viewfinder", title: "截图记账", primary: "继续") {
                            path.append(.rates)
                        } content: {
                            ScreenshotSetupSections()
                        }
                    case .rates:
                        SetupPage(symbol: "arrow.triangle.2.circlepath", title: "汇率", primary: "完成") {
                            finish()
                        } content: {
                            ExchangeRateSetupSections()
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

/// 第 1 页：还没有账户时只有「添加银行卡」和「跳过」；添加了以后列出来，可以再加，按钮换成「继续」
private struct AccountsPage: View {
    let next: () -> Void
    @Environment(LedgerStore.self) private var store
    @State private var adding = false

    var body: some View {
        let added = !store.accounts.isEmpty
        SetupPage(
            symbol: "creditcard",
            title: "添加银行卡",
            primary: added ? "继续" : "添加银行卡",
            primaryAction: { if added { next() } else { adding = true } },
            secondary: added ? nil : "跳过",
            secondaryAction: next
        ) {
            if added {
                Section {
                    ForEach(store.accounts) { AccountSummaryRow(account: $0) }
                    Button("添加银行卡", systemImage: "plus") { adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) { AddAccountView() }
    }
}

/// 第 3 页：把「记账结果」设成「全部」并请求通知权限，记上一笔没分类的就在灵动岛（没有灵动岛的手机在通知）上选分类。
/// 不给权限时和「我的」里一样保持关闭
private struct ResultsPage: View {
    let next: () -> Void
    private let island = DynamicIsland.isPresent(model: LiveCategoryActivity.modelIdentifier)

    var body: some View {
        SetupPage(
            symbol: island ? "iphone.gen3" : "bell.badge",
            title: island ? "在灵动岛上选分类" : "在通知上选分类",
            primary: "打开",
            primaryAction: turnOn,
            secondary: "跳过",
            secondaryAction: next
        ) {
            EmptyView()
        }
    }

    private func turnOn() {
        Task {
            if await IngestNotifier.requestAuthorization() {
                UserDefaults.standard.set(IngestNotifier.Mode.all.rawValue, forKey: IngestNotifier.modeKey)
            }
            next()
        }
    }
}

/// 新机设置那样的一页：白底，上面大图标和大标题，中间灰色圆角的内容，下面整行宽的主按钮和一个文字按钮
private struct SetupPage<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let primary: LocalizedStringKey
    let primaryAction: () -> Void
    let secondary: LocalizedStringKey?
    let secondaryAction: () -> Void
    let content: Content

    init(
        symbol: String,
        title: LocalizedStringKey,
        primary: LocalizedStringKey,
        primaryAction: @escaping () -> Void,
        secondary: LocalizedStringKey? = nil,
        secondaryAction: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.title = title
        self.primary = primary
        self.primaryAction = primaryAction
        self.secondary = secondary
        self.secondaryAction = secondaryAction
        self.content = content()
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
                .listRowBackground(Color(.secondarySystemBackground))
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: primaryAction) {
                    Text(primary).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if let secondary {
                    Button(secondary, action: secondaryAction)
                        .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
