import SwiftUI
import UIKit

/// 页面顶部一行的磨砂背景：列表滚到这一行下面时出现，往下渐渐变淡。首页、统计页、「我的」用。
///
/// 不用系统的滚动边缘效果：系统的效果按这一行里的文字决定画在哪，首页搜索展开、标题淡出时它会突然消失。
/// 这里只看列表有没有滚到下面，搜索展开、收起都不变。
struct TopBarBackdrop: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.65), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            // 往下多盖一点，渐变到透明；往上盖住状态栏
            .padding(.bottom, -18)
            .ignoresSafeArea(edges: .top)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 列表有没有滚到顶部那一行下面（给 `TopBarBackdrop` 用）；同时关掉系统的上边缘效果，免得画两层
    func trackingScrollUnderTopBar(_ scrolled: Binding<Bool>) -> some View {
        scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, value in
                scrolled.wrappedValue = value
            }
    }
}

/// 页面顶部一行：左边大标题，右边可以有几个玻璃胶囊下拉按钮（写着当前选的，点开是菜单）。
/// 和首页、资产页的标题行一样高、一样的字号。统计页用它选看哪些数据和时间段（时间段和卡片详情的时间段胶囊一样）；「我的」只有标题。
struct TitleBar: UIViewRepresentable {
    struct Menu {
        /// 胶囊上写的字，例如「本月」
        let title: String
        /// 每次打开菜单时生成，显示的永远是当时的状态
        let items: @MainActor () -> [UIMenuElement]
    }

    let title: String
    /// 从左到右
    var menus: [Menu] = []

    func makeUIView(context: Context) -> TitleBarView {
        TitleBarView(title: title, menuCount: menus.count)
    }

    func updateUIView(_ view: TitleBarView, context: Context) {
        for (index, menu) in menus.enumerated() {
            view.setMenu(index, title: menu.title, items: menu.items)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TitleBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: GlassControls.size)
    }
}

@MainActor
final class TitleBarView: UIView {
    private let titleLabel = UILabel()
    private let container = GlassControls.container()
    private let capsules: [UIVisualEffectView]
    private let menuButtons: [UIButton]
    private var menuTitles: [String]
    private var menuItems: [@MainActor () -> [UIMenuElement]]

    init(title: String, menuCount: Int) {
        capsules = (0..<menuCount).map { _ in GlassControls.capsule(GlassControls.glass()) }
        menuButtons = (0..<menuCount).map { _ in UIButton(configuration: GlassControls.pillConfiguration("")) }
        menuTitles = Array(repeating: "", count: menuCount)
        menuItems = Array(repeating: { [] }, count: menuCount)
        super.init(frame: .zero)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        titleLabel.font = metrics.scaledFont(for: UIFont.systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = title
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)

        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isHidden = menuCount == 0
        addSubview(container)
        for (index, (capsule, button)) in zip(capsules, menuButtons).enumerated() {
            container.contentView.addSubview(capsule)
            button.showsMenuAsPrimaryAction = true
            button.menu = GlassControls.deferredMenu { [weak self] in self?.menuItems[index]() ?? [] }
            capsule.contentView.addSubview(button)
        }
        accessibilityElements = [titleLabel as UIView] + (menuButtons as [UIView])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 胶囊上写的字和菜单；宽度跟着字变（玻璃胶囊伸缩）
    func setMenu(_ index: Int, title: String, items: @escaping @MainActor () -> [UIMenuElement]) {
        guard menuButtons.indices.contains(index) else { return }
        menuItems[index] = items
        guard title != menuTitles[index] else { return }
        let first = menuTitles[index].isEmpty
        menuTitles[index] = title
        let button = menuButtons[index]
        UIView.performWithoutAnimation {
            button.configuration = GlassControls.pillConfiguration(title)
            button.layoutIfNeeded()
        }
        setNeedsLayout()
        if !first, window != nil {
            GlassControls.morph { self.layoutIfNeeded() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = GlassControls.size
        var widths = menuButtons.map { GlassControls.pillWidth($0) }
        // 放不下时缩最左边的胶囊（字截断），标题完整显示
        let room = bounds.width - 4 - titleLabel.intrinsicContentSize.width - CGFloat(widths.count) * GlassControls.gap
        if let first = widths.indices.first, widths.reduce(0, +) > room {
            widths[first] = max(size * 2, room - widths.dropFirst().reduce(0, +))
        }
        var x = bounds.width
        for index in menuButtons.indices.reversed() {
            x -= widths[index]
            GlassControls.place(capsules[index], CGRect(x: x, y: 0, width: widths[index], height: size))
            menuButtons[index].frame = CGRect(x: 0, y: 0, width: widths[index], height: size)
            x -= GlassControls.gap
        }
        titleLabel.frame = CGRect(x: 4, y: 0, width: max(0, x - 4), height: size)
    }

    /// 只有玻璃接收触摸，标题和空白处不挡住下面的列表
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return capsules.contains { hit.isDescendant(of: $0) } ? hit : nil
    }
}
