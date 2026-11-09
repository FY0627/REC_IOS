import SwiftUI
import Observation

/// 单变量性能开关。每个开关只控制一件事，便于在真机上做 A/B 对照：
/// 一次只改一个开关，其余保持默认，录屏或看调试指标对比。
/// 标签栏、导航栏和按钮都是系统原生控件（液态玻璃由系统渲染），不在这里切换。
@MainActor
@Observable
final class PerfFlags {
    static let shared = PerfFlags()

    private let defaults = UserDefaults.standard

    /// 卡片阴影（每张卡一个圆角矩形的形状阴影）
    var cardShadows: Bool { didSet { defaults.set(cardShadows, forKey: "perf.cardShadows") } }
    /// 卡面先合成为一张位图（drawingGroup）再参与滚动和转场
    var rasterizeCards: Bool { didSet { defaults.set(rasterizeCards, forKey: "perf.rasterizeCards") } }
    /// 卡面图片用遮罩裁圆角（默认关：圆角已经画在位图里，打开是为了和原来的做法对照）
    var clipCardPhotos: Bool { didSet { defaults.set(clipCardPhotos, forKey: "perf.clipCardPhotos") } }
    /// 图片卡上的金额和描边合成一张小位图
    var flattenCardAmount: Bool { didSet { defaults.set(flattenCardAmount, forKey: "perf.flattenCardAmount") } }
    /// 返回卡包时下面的卡用不回弹的弹簧升回来
    var gentleCardReturn: Bool { didSet { defaults.set(gentleCardReturn, forKey: "perf.gentleCardReturn") } }
    /// 返回卡包时等动画全部停稳再清空详情列表（关：0.5 秒时清空，这时卡片还在收尾）
    var lateDetailCleanup: Bool { didSet { defaults.set(lateDetailCleanup, forKey: "perf.lateDetailCleanup") } }
    /// 位移的弹簧走到离终点 0.05pt 以内才结束（关：用系统的 `settlingDuration`，走得远的卡最后一步跳过去）
    var settleSprings: Bool { didSet { defaults.set(settleSprings, forKey: "perf.settleSprings") } }
    /// 转场的位移动画向系统要 80–120Hz（关：刷新率由系统决定）
    var holdHighRefresh: Bool { didSet { defaults.set(holdHighRefresh, forKey: "perf.holdHighRefresh") } }
    /// 屏幕角落的帧率 / 内存调试指标
    var showMetrics: Bool { didSet { defaults.set(showMetrics, forKey: "perf.showMetrics") } }
    /// 对齐参考线（`AlignmentGuides`）：查资产页的「合计」和首页、统计的第一组对不对齐
    var showAlignmentGuides: Bool { didSet { defaults.set(showAlignmentGuides, forKey: "perf.showAlignmentGuides") } }

    private init() {
        cardShadows = UserDefaults.standard.object(forKey: "perf.cardShadows") as? Bool ?? true
        rasterizeCards = UserDefaults.standard.object(forKey: "perf.rasterizeCards") as? Bool ?? false
        clipCardPhotos = UserDefaults.standard.object(forKey: "perf.clipCardPhotos") as? Bool ?? false
        flattenCardAmount = UserDefaults.standard.object(forKey: "perf.flattenCardAmount") as? Bool ?? true
        gentleCardReturn = UserDefaults.standard.object(forKey: "perf.gentleCardReturn") as? Bool ?? true
        lateDetailCleanup = UserDefaults.standard.object(forKey: "perf.lateDetailCleanup") as? Bool ?? true
        settleSprings = UserDefaults.standard.object(forKey: "perf.settleSprings") as? Bool ?? true
        holdHighRefresh = UserDefaults.standard.object(forKey: "perf.holdHighRefresh") as? Bool ?? true
        showMetrics = UserDefaults.standard.object(forKey: "perf.showMetrics") as? Bool ?? false
        showAlignmentGuides = UserDefaults.standard.object(forKey: "perf.showAlignmentGuides") as? Bool ?? false
    }

    func resetToDefaults() {
        cardShadows = true
        rasterizeCards = false
        clipCardPhotos = false
        flattenCardAmount = true
        gentleCardReturn = true
        lateDetailCleanup = true
        settleSprings = true
        holdHighRefresh = true
        showMetrics = false
        showAlignmentGuides = false
    }

    /// 当前开关组合的简短描述，录屏对照时显示在调试指标里
    var summary: String {
        "shadow=\(cardShadows ? 1 : 0) raster=\(rasterizeCards ? 1 : 0) clip=\(clipCardPhotos ? 1 : 0) flat=\(flattenCardAmount ? 1 : 0) rise=\(gentleCardReturn ? 1 : 0) late=\(lateDetailCleanup ? 1 : 0) land=\(settleSprings ? 1 : 0) hz=\(holdHighRefresh ? 1 : 0)"
    }
}
