import SwiftUI
import QuartzCore
import Darwin

/// App 内调试指标：帧率、超过两个刷新周期的长帧次数、内存占用，和最近一次卡包转场的读数。
/// 用于没有 Instruments 的真机对照：打开后录屏，比较同一操作在不同开关下的读数。
/// 读数只是粗略参考，不等同于 Instruments 的帧耗时测量。
/// 计时跑在主线程上，看到的长帧是主线程的；Core Animation 播放的动画不受主线程影响，长帧不一定等于动画卡了。
@MainActor
@Observable
final class FrameMonitor {
    /// 调试指标打开时的监视器；卡包转场开始时让它盯住一张卡
    static weak var current: FrameMonitor?

    private(set) var fps: Int = 0
    private(set) var longFrames: Int = 0
    private(set) var memoryMB: Int = 0
    private(set) var maxRefresh: Int = 0
    /// 最近一次转场的读数。转场结束才更新：途中刷新这行字本身就是主线程的工作
    private(set) var lastTransition = ""

    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var proxy: Proxy?
    private var watched: WatchedCard?

    /// 正在盯的卡
    private struct WatchedCard {
        let layer: CALayer
        let title: String
        let start: CFTimeInterval
        /// 显示位置还差模型位置多远
        var offset: CGFloat = 0
        /// 比一个刷新周期明显长的帧：转场开始后多久、多长
        var slowFrames: [(at: CFTimeInterval, gap: CFTimeInterval)] = []
    }

    private final class Proxy: NSObject {
        weak var owner: FrameMonitor?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }

    func start() {
        guard link == nil else { return }
        Self.current = self
        let proxy = Proxy()
        proxy.owner = self
        self.proxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        windowStart = CACurrentMediaTime()
        lastTimestamp = 0
        frames = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
        watched = nil
        Self.current = nil
    }

    /// 盯住一张正在转场的卡，它落定后在调试指标里写一行
    func watch(_ layer: CALayer, title: String) {
        watched = WatchedCard(layer: layer, title: title, start: CACurrentMediaTime())
    }

    private func tick(_ link: CADisplayLink) {
        frames += 1
        let expected = link.targetTimestamp - link.timestamp
        let gap = lastTimestamp > 0 ? link.timestamp - lastTimestamp : 0
        if expected > 0, gap > expected * 2.1 { longFrames += 1 }
        lastTimestamp = link.timestamp
        if watched != nil { updateWatched(now: link.timestamp, gap: gap, expected: expected) }
        let elapsed = link.timestamp - windowStart
        if elapsed >= 1 {
            fps = Int((Double(frames) / elapsed).rounded())
            if expected > 0 { maxRefresh = Int((1 / expected).rounded()) }
            frames = 0
            windowStart = link.timestamp
            memoryMB = Self.footprintMB()
        }
    }

    /// 叠加动画一结束，显示位置就回到模型位置：动画最后一帧还差多远，卡片就一步跳多远
    private func updateWatched(now: CFTimeInterval, gap: CFTimeInterval, expected: CFTimeInterval) {
        guard var card = watched else { return }
        if gap > expected * 1.5 { card.slowFrames.append((at: now - card.start, gap: gap)) }
        let model = card.layer.position.y
        let offset = abs((card.layer.presentation()?.position.y ?? model) - model)
        guard (offset < 0.001 && card.offset > 0) || now - card.start > 2 else {
            card.offset = offset
            watched = card
            return
        }
        let slowest = card.slowFrames.sorted { $0.gap > $1.gap }.prefix(3).sorted { $0.at < $1.at }
        let times = slowest.map { String(format: "%.2fs %.0fms", $0.at, $0.gap * 1000) }
        let jump = String(format: "%.2f", card.offset)
        lastTransition = "\(card.title) 末帧跳 \(jump)pt · 长帧 \(times.isEmpty ? "无" : times.joined(separator: " "))"
        watched = nil
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }
}

struct MetricsOverlay: View {
    @State private var monitor = FrameMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(monitor.fps) fps / \(monitor.maxRefresh) Hz")
            Text("长帧 \(monitor.longFrames) · 内存 \(monitor.memoryMB) MB")
            Text(PerfFlags.shared.summary)
            if !monitor.lastTransition.isEmpty { Text(monitor.lastTransition) }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
