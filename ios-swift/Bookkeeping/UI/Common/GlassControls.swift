import UIKit

/// UIKit 液态玻璃按钮的共用部分：资产页（`WalletTopBar`）和首页（`HomeTopBarView`）顶部那一行。
///
/// 同一个玻璃容器（`UIGlassContainerEffect`）里的玻璃重叠时画成一整块；相距不到 `mergeSpacing` 时中间连着一道细颈，
/// 越近越粗，像两滴水粘在一起。按钮分开 / 合上时一路移动，细颈从粗拉到细再断开（合上时反过来）。
///
/// 和 Apple 的做法一样，停下来的间距 `gap` 和融合距离差不多大，只稍大一点：
/// - 融合距离太小（第一版 8pt）：细颈一闪而过，看起来像一个按钮从另一个按钮下面滑出来；
/// - 停下时还在融合距离以内（更早一版间距 10pt、融合距离 16pt）：中间一直连着一道带尖角的细颈。
///
/// 位置和大小用 UIKit 的弹簧动画，交给 Core Animation，由系统渲染进程播放，主线程忙也不掉帧。
///
/// 弹一下：分出来停到空处时冲过一点再弹回（`split`）；并进另一块时不冲过头（冲过头会从另一边飞出去），
/// 停稳后整块横向鼓一下再弹回（`settle`），像两滴水并成一滴。
@MainActor
enum GlassControls {
    /// 和系统导航栏按钮一样：44pt 高
    static let size: CGFloat = 44
    static let mergeSpacing: CGFloat = 22
    static let gap: CGFloat = 24

    static func container() -> UIVisualEffectView {
        let effect = UIGlassContainerEffect()
        effect.spacing = mergeSpacing
        return UIVisualEffectView(effect: effect)
    }

    /// `interactive`：按住时系统让玻璃鼓起来、发亮。被按住的这块玻璃画在上层，不和同一容器里的其他玻璃融合：
    /// 一边按着它一边从它下面分出别的玻璃，看起来像一个圆盖在水滴上面。要和别的玻璃分合的按钮用 `false`，
    /// 按下的反馈自己做（`pressFeedback`）
    static func glass(interactive: Bool = true) -> UIGlassEffect {
        let effect = UIGlassEffect()
        effect.isInteractive = interactive
        return effect
    }

    /// 不用系统交互效果的玻璃按下时：整块稍微鼓起来，松手弹回（带回弹）。只改缩放，和位置动画互不影响
    static func pressFeedback(_ controls: [UIControl], glass: UIView) {
        for control in controls {
            control.addAction(UIAction { [weak glass] _ in if let glass { press(glass, down: true) } }, for: [.touchDown, .touchDragEnter])
            control.addAction(
                UIAction { [weak glass] _ in if let glass { press(glass, down: false) } },
                for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
            )
        }
    }

    private static func press(_ glass: UIView, down: Bool) {
        let scale: CGFloat = down ? 1.12 : 1
        UIView.animate(
            springDuration: down ? 0.25 : 0.5, bounce: down ? 0 : 0.45, initialSpringVelocity: 0, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            glass.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    /// 胶囊形状的一块玻璃；`effect` 为 nil 时先不显示，之后设成玻璃时系统播放「凝结」动画
    static func capsule(_ effect: UIVisualEffect?) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }

    /// 44pt 点按区域、17pt 图标，文字颜色（不跟随强调色）
    static func iconButton(_ symbol: String, label: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        return button
    }

    /// 胶囊里的下拉按钮：文字 + 上下箭头
    static func pillConfiguration(_ title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        var text = AttributedString(title)
        text.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        config.attributedTitle = text
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14)
        // 胶囊放不下时截断后面的字
        config.titleLineBreakMode = .byTruncatingTail
        return config
    }

    /// 放得下按钮内容的胶囊宽度，至少是圆形按钮那么宽
    static func pillWidth(_ button: UIButton) -> CGFloat {
        max(size, ceil(button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size)).width))
    }

    /// 每次打开菜单时才生成菜单项，显示的永远是当时的状态
    static func deferredMenu(_ items: @escaping @MainActor () -> [UIMenuElement]) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion(items()) }
            }
        ])
    }

    /// 展开的弹簧：带一点回弹，分出来时弹一下
    static let morphDuration = 0.55
    static let morphBounce = 0.3
    /// 展开动画基本停稳的时间；这之前合上要从半路接着走（见 `reverseMorph`）
    static let morphSettle = 0.65

    /// 分开（展开）：弹簧动画，带一点回弹。`bounce` 为 0 时不回弹（中途转向用）。
    /// `completion` 收到 false 表示被新的动画打断
    static func morph(
        _ changes: @escaping () -> Void, bounce: Double = morphBounce, delay: Double = 0, completion: ((Bool) -> Void)? = nil
    ) {
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: delay, options: options, animations: changes, completion: completion)
        } else {
            UIView.animate(
                springDuration: morphDuration, bounce: bounce, initialSpringVelocity: 0, delay: delay, options: options,
                animations: changes, completion: completion
            )
        }
    }

    /// 短距离分出来的回弹：移动的距离只有一个按钮宽，`morphBounce` 冲过的那一点看不出来，加大一些
    static let splitBounce = 0.42

    /// 分出来、停到空处：冲过一点再弹回
    static func split(_ changes: @escaping () -> Void, delay: Double = 0, completion: ((Bool) -> Void)? = nil) {
        morph(changes, bounce: splitBounce, delay: delay, completion: completion)
    }

    /// 并进另一块玻璃：不冲过头，停稳后由 `settle` 弹一下
    static func merge(_ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: options, animations: changes, completion: completion)
        } else {
            UIView.animate(springDuration: 0.34, bounce: 0, initialSpringVelocity: 0, delay: 0, options: options, animations: changes, completion: completion)
        }
    }

    /// 并好停稳后弹一下：整块先横向鼓起、竖向压扁一点，再回弹到原样。只改缩放
    static func settle(_ view: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animateKeyframes(
            withDuration: 0.45, delay: 0, options: [.calculationModeCubic, .beginFromCurrentState, .allowUserInteraction],
            animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.28) {
                    view.transform = CGAffineTransform(scaleX: 1.07, y: 0.93)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.28, relativeDuration: 0.3) {
                    view.transform = CGAffineTransform(scaleX: 0.98, y: 1.02)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.42) {
                    view.transform = .identity
                }
            }
        )
    }

    /// 停在动画当前显示的位置：去掉还在进行（或还没开始）的位置动画，模型值改成看到的样子。
    /// 之后再加的动画从这里出发，不会先跳到旧动画的终点
    static func freeze(_ view: UIView) {
        guard let shown = view.layer.presentation() else { return }
        let bounds = shown.bounds, position = shown.position
        // UIKit 的叠加动画各有各的键，按键删不干净
        view.layer.removeAllAnimations()
        view.bounds = CGRect(origin: .zero, size: bounds.size)
        view.center = position
    }

    /// 合上用的时间，和卡片转场的节奏差不多
    static let reverseDuration = 0.4

    /// 合上：把展开动画倒过来播放，玻璃沿原路退回去。
    ///
    /// `apply(progress)` 按进度摆好位置：0 是展开的样子，1 是合上的样子。展开的弹簧从静止出发，
    /// 倒过来正好在合上的位置停稳，不会像另起一个弹簧那样冲过头（飞出去）再弹回来。
    /// 只倒放弹簧第一次走到终点之前的那一段：之后只是轻轻回弹、慢慢停稳，倒过来就是开头一大段几乎不动，
    /// 要等页面的动画快结束了才开始缩回。
    /// 用 UIKit 的关键帧动画（Core Animation 播放）逐段跟着弹簧的轨迹走，玻璃内部跟着一起变化。
    static func reverseMorph(_ apply: @escaping (CGFloat) -> Void, completion: @escaping (Bool) -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: { apply(1) }, completion: completion)
            return
        }
        let steps = 24
        let arrival = firstArrival
        UIView.animateKeyframes(
            withDuration: reverseDuration, delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState, .allowUserInteraction],
            animations: {
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    let progress = 1 - springProgress(arrival * (1 - fraction))
                    UIView.addKeyframe(withRelativeStartTime: Double(step - 1) / Double(steps), relativeDuration: 1 / Double(steps)) {
                        apply(CGFloat(progress))
                    }
                }
            },
            completion: completion
        )
    }

    /// 展开弹簧第一次走到终点的时间（约 0.29 秒）。之后冲过一点再回来、慢慢停稳
    private static var firstArrival: Double {
        let omega = 2 * Double.pi / morphDuration
        let zeta = 1 - morphBounce
        let root = (1 - zeta * zeta).squareRoot()
        guard root > 0.01 else { return morphDuration }
        return (Double.pi - atan(root / zeta)) / (omega * root)
    }

    /// 展开弹簧在 `time` 秒时走了多少（0 → 1，中途会略超过 1 再回来）。
    /// 和 UIKit 的 `springDuration` / `bounce` 换算一致：固有频率 2π / duration，阻尼比 1 - bounce
    static func springProgress(_ time: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / morphDuration
        let zeta = 1 - morphBounce
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * time)
        return 1 - decay * (cos(omegaD * time) + zeta * omega / omegaD * sin(omegaD * time))
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    /// 视图现在的位置（用 bounds 和 center 算，视图可能带着缩放）
    static func frame(of view: UIView) -> CGRect {
        CGRect(x: view.center.x - view.bounds.width / 2, y: view.center.y - view.bounds.height / 2,
               width: view.bounds.width, height: view.bounds.height)
    }

    /// 合在一起静止时只留一块玻璃：叠在下面的几块去掉玻璃效果（不播放消散动画）。
    /// 叠着的几块玻璃画出来是一整块，但按住时只有手指下面那块会动，会露出是几个按钮叠在一起。
    /// 要分开时先不带动画加回玻璃效果：和上面那块完全重叠，看不出变化，再一起动画分开
    static func setGlass(_ views: [UIVisualEffectView], _ on: Bool) {
        UIView.performWithoutAnimation {
            for view in views { view.effect = on ? glass() : nil }
        }
    }

    /// 玻璃里的文字和图标：要消失的马上淡出；要出现的等玻璃差不多分开了再淡入，
    /// 不会在别的玻璃上面滑过去（那样看起来像两个按钮叠在一起）
    static func swapContent(show: [UIView], hide: [UIView], showDelay: Double = 0.22) {
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        UIView.animate(withDuration: 0.12, delay: 0, options: options) {
            for view in hide { view.alpha = 0 }
        }
        UIView.animate(withDuration: 0.2, delay: showDelay, options: options) {
            for view in show { view.alpha = 1 }
        }
    }

    /// 摆放可能带着缩放的视图：用 bounds 和 center，不直接设 frame
    static func place(_ view: UIView, _ rect: CGRect) {
        if view.bounds.size != rect.size { view.bounds = CGRect(origin: .zero, size: rect.size) }
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }
}
