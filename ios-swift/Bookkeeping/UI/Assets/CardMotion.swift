import UIKit

/// 卡包转场用的 Core Animation 动画。
///
/// 动画加在图层上，由系统的渲染进程逐帧播放，不占用 App 的主线程：动画途中读流水、生成列表行，动画也不会停顿。
/// 这是和 Apple 钱包一样的做法；SwiftUI 的动画要主线程每一帧参与计算，主线程一忙就掉帧。
///
/// 位置用「叠加动画」：模型值直接改成终点，动画只描述「显示位置比模型值差多少」，从起点的差值过渡到 0。
/// 动画途中模型值再变（滚动、再次点按），新的差值叠加上去，卡片从当前位置带着速度平滑转向，不跳。
@MainActor
enum CardMotion {
    enum Timing {
        /// 和 SwiftUI 的 `.spring(response:dampingFraction:)` 相同的弹簧
        case spring(response: Double, damping: Double)
        case easeIn(Double)
        case easeOut(Double)
        case easeInOut(Double)
    }

    /// 选中的卡和收到后面的卡；和标签栏的 SwiftUI 动画（`DetailMotionState.transition`）同一个弹簧
    static func transition(reduceMotion: Bool) -> Timing {
        reduceMotion ? .easeInOut(0.25) : .spring(response: 0.5, damping: 0.86)
    }

    /// 详情内容从屏幕底下升上来：不回弹，不会顶到卡片下面
    static func entrance(reduceMotion: Bool) -> Timing {
        reduceMotion ? .easeOut(0.2) : .spring(response: 0.5, damping: 1)
    }

    /// 下面的卡落出屏幕：加速下落
    static let drop = Timing.easeIn(0.25)
    /// 返回时下面的卡升回来比选中的卡晚一点，让详情内容先开始退下
    static let riseDelay = 0.06

    /// 收到选中卡后面的卡只缩小，不做 3D 倾斜：卡片一旦带透视的 3D 变换，Core Animation 会按深度给同一层的卡排序，
    /// 倾斜的卡会穿过选中的卡，返回途中卡片的上下层也会颠倒，直到动画结束才恢复
    static let behindScale: CGFloat = 0.86
    static let behindTransform = CATransform3DMakeScale(behindScale, behindScale, 1)

    /// 位移的弹簧走到离终点这么近才结束
    private static let restDistance = 0.05
    /// 位移动画要的刷新率：Apple 给「点开全屏」这类动画的推荐值。不设时由系统决定，动画途中可能变
    private static let moveFrameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    /// 叠加动画各用一个新的键，后加的不替换还在进行的
    private static var counter = 0

    /// `distance`：这次位移走多远，透明度、缩放不用填
    static func animation(_ timing: Timing, keyPath: String, distance: CGFloat = 0) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch timing {
        case .spring(let response, let damping):
            // 质量 1；刚度和阻尼按 SwiftUI 的换算：固有频率 2π / response，阻尼比 dampingFraction
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = CGFloat(pow(2 * Double.pi / response, 2))
            spring.damping = CGFloat(4 * Double.pi * damping / response)
            let rest = PerfFlags.shared.settleSprings ? restTime(response: response, damping: damping, distance: distance) : 0
            spring.duration = max(spring.settlingDuration, rest)
            animation = spring
        case .easeIn(let duration):
            animation = curve(keyPath, duration, .easeIn)
        case .easeOut(let duration):
            animation = curve(keyPath, duration, .easeOut)
        case .easeInOut(let duration):
            animation = curve(keyPath, duration, .easeInEaseOut)
        }
        if distance > 0, PerfFlags.shared.holdHighRefresh {
            animation.preferredFrameRateRange = moveFrameRate
        }
        return animation
    }

    /// 弹簧离终点不到 `restDistance` 的时间。`settlingDuration` 只看弹簧参数，不知道这次走多远，大约在走完全程的 99.92% 时结束：
    /// 下面的卡走一整屏（约 870pt），这时还差 0.7pt，而每帧只走 0.1pt，动画一结束就一步跳到终点，看起来顿一下。
    /// `(1 + ωt)·e^(-ζωt)` 是弹簧衰减的上界，阻尼 1 时正好相等。弹簧的轨迹不变，只是不提前截断
    private static func restTime(response: Double, damping: Double, distance: CGFloat) -> Double {
        let omega = 2 * Double.pi / response
        var time = 0.0
        while Double(distance) * (1 + omega * time) * exp(-damping * omega * time) > restDistance {
            time += 1.0 / 120
        }
        return time
    }

    private static func curve(_ keyPath: String, _ duration: Double, _ name: CAMediaTimingFunctionName) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: name)
        return animation
    }

    /// 延迟开始；开始之前保持起点
    private static func delay(_ animation: CAAnimation, on layer: CALayer, by delay: Double) {
        guard delay > 0 else { return }
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
    }

    /// 竖直位置的模型值已经改成终点；显示位置从比终点高 `deltaY`（起点 - 终点）的地方过渡过去。
    static func addMove(_ layer: CALayer, deltaY: CGFloat, timing: Timing, delay: Double = 0) {
        guard abs(deltaY) > 0.5 else { return }
        let animation = Self.animation(timing, keyPath: "position.y", distance: abs(deltaY))
        animation.isAdditive = true
        animation.fromValue = deltaY
        animation.toValue = 0
        Self.delay(animation, on: layer, by: delay)
        counter += 1
        layer.add(animation, forKey: "move.\(counter)")
    }

    /// 把变换改成 `target`，从当前显示的样子过渡过去（动画中途改变也不跳）。`timing` 为 nil 时直接设置
    static func setTransform(_ layer: CALayer, _ target: CATransform3D, timing: Timing?) {
        let from = layer.presentation()?.transform ?? layer.transform
        layer.transform = target
        guard let timing, !CATransform3DEqualToTransform(from, target) else {
            layer.removeAnimation(forKey: "transform")
            return
        }
        let animation = Self.animation(timing, keyPath: "transform", distance: abs(from.m42 - target.m42))
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)
        layer.add(animation, forKey: "transform")
    }

    /// 把透明度改成 `target`，从当前显示的透明度过渡过去。`timing` 为 nil 时直接设置
    static func setOpacity(_ layer: CALayer, _ target: Float, timing: Timing?, delay: Double = 0) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = target
        guard let timing, from != target else {
            layer.removeAnimation(forKey: "opacity")
            return
        }
        let animation = Self.animation(timing, keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        Self.delay(animation, on: layer, by: delay)
        layer.add(animation, forKey: "opacity")
    }

    /// 模型值不变，显示从 `offsetY` 处和透明度 0 过渡到模型值（详情内容从屏幕底下升上来）
    static func rise(_ layer: CALayer, from offsetY: CGFloat, timing: Timing) {
        let move = Self.animation(timing, keyPath: "transform", distance: abs(offsetY))
        move.fromValue = NSValue(caTransform3D: CATransform3DConcat(layer.transform, CATransform3DMakeTranslation(0, offsetY, 0)))
        move.toValue = NSValue(caTransform3D: layer.transform)
        layer.add(move, forKey: "transform")
        let fade = Self.animation(timing, keyPath: "opacity")
        fade.fromValue = Float(0)
        fade.toValue = layer.opacity
        layer.add(fade, forKey: "opacity")
    }
}
