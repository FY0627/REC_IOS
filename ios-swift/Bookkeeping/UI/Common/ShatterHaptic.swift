import CoreHaptics
import UIKit

/// 碎掉的震动：分类拖进删除图标删掉时用。
/// 先「咔」一下又重又脆（裂开），紧跟着一下闷一点的，再是一串越来越轻、轻重不一的小颗粒（碎片落下），
/// 底下垫一段很短的低沉嗡声，一共不到 0.3 秒。用 Core Haptics 自己排；手机不支持（没有 Taptic Engine）时换成一下重的震动。
/// 引擎平时不开：`prepare()` 时才开，震完一会儿没用就由系统停掉（`isAutoShutdownEnabled`）
@MainActor
final class ShatterHaptic {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func prepare() {
        guard supported else {
            fallback.prepare()
            return
        }
        do {
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.isAutoShutdownEnabled = true
                // 被系统停掉（来电、切到后台）后下次要重新做播放器
                engine.resetHandler = { [weak self] in Task { @MainActor in self?.player = nil } }
                engine.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.player = nil } }
                self.engine = engine
            }
            try engine?.start()
            if player == nil { player = try engine?.makePlayer(with: Self.pattern()) }
        } catch {
            engine = nil
            player = nil
        }
    }

    func play() {
        guard supported else {
            fallback.impactOccurred(intensity: 1)
            return
        }
        if player == nil { prepare() }
        do {
            try engine?.start()
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.impactOccurred(intensity: 1)
        }
    }

    private nonisolated static func pattern() throws -> CHHapticPattern {
        func tap(_ time: TimeInterval, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: time
            )
        }
        // 碎片：时间越来越松、越来越轻，脆的和闷的错开
        let debris: [(TimeInterval, Float, Float)] = [
            (0.060, 0.70, 0.85),
            (0.085, 0.55, 0.40),
            (0.115, 0.50, 0.95),
            (0.150, 0.38, 0.55),
            (0.190, 0.28, 0.90),
            (0.235, 0.18, 0.45),
            (0.280, 0.12, 0.80),
        ]
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ],
            relativeTime: 0,
            duration: 0.14
        )
        // 嗡声很快弱下去
        let fade = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.14, value: 0),
            ],
            relativeTime: 0
        )
        let events = [tap(0, 1, 1), tap(0.025, 0.8, 0.3), rumble] + debris.map { tap($0.0, $0.1, $0.2) }
        return try CHHapticPattern(events: events, parameterCurves: [fade])
    }
}
