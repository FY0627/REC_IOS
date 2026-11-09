import SwiftUI
import UIKit

/// 对齐参考线：盖在所有标签页上面的三条横线，位置是首页量出来的（`FirstBoxLayout`），资产页的「合计」和净资产卡按它排。
/// 红线：分组标题文字的底边；蓝线：第一个白框的顶端；绿线：白框里第一行字的顶端（白框顶端加上格子的边距）。
/// 在首页看线和首页自己的字、白框对不对得上（量得对不对），在资产页看「合计」和卡片对不对得上（排得对不对）。
/// 下面一块小字是读数（`AlignmentDebug`），单位 pt，位置从状态栏下面算。
struct AlignmentGuides: View {
    var body: some View {
        GeometryReader { proxy in
            // 和首页、资产页一样从窗口的安全区算（状态栏下面），减去这一层在窗口里的位置
            let top = Self.windowSafeTop - proxy.frame(in: .global).minY
            if let first = FirstBoxLayout.shared.home {
                let contentTop = first.box + (FirstBoxLayout.shared.homeRowInsets?.top ?? 0) + ConvertedTotalsView.verticalPadding
                line(.red, y: top + first.title)
                line(.blue, y: top + first.box)
                line(.green, y: top + contentTop)
            }
            readings
                .offset(y: proxy.size.height * 0.55)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var readings: some View {
        let first = FirstBoxLayout.shared.home
        let insets = FirstBoxLayout.shared.homeRowInsets
        let debug = AlignmentDebug.shared
        return VStack(alignment: .leading, spacing: 2) {
            Text("home title \(Self.number(first?.title)) box \(Self.number(first?.box)) inset \(Self.number(insets?.top))")
            Text("asset title \(Self.number(debug.assetTitleBottom)) box \(Self.number(debug.assetCardTop)) scrolled \(Self.number(debug.assetScrolled))")
            Text("asset height fit \(Self.number(debug.assetFittedHeight)) rendered \(Self.number(debug.assetRenderedHeight))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 8)
    }

    private static func number(_ value: CGFloat?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f", value)
    }

    private static var windowSafeTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.compactMap(\.keyWindow).first?.safeAreaInsets.top ?? 0
    }

    private func line(_ color: Color, y: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .offset(y: y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 对齐参考线打开时资产页记下的读数。位置在卡包滚动区的内容里算：没往下拉开时内容的顶端就是状态栏下面，
/// 和首页量的（`FirstBoxPosition`）直接比
@MainActor
@Observable
final class AlignmentDebug {
    static let shared = AlignmentDebug()
    /// 「合计」这行字的底边
    var assetTitleBottom: CGFloat?
    /// 净资产卡的顶端
    var assetCardTop: CGFloat?
    /// 卡包往上滚了多少；往下拉开时是负数
    var assetScrolled: CGFloat = 0
    /// 标题区：`sizeThatFits` 算的高度、SwiftUI 实际排出来的高度
    var assetFittedHeight: CGFloat = 0
    var assetRenderedHeight: CGFloat = 0
}

/// 量一块内容在它所在的滚动区里的位置（内容坐标，滚动不影响结果）。只在打开对齐参考线时放
struct ScrollContentFrameProbe: UIViewRepresentable {
    let report: @MainActor (CGRect) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.report = report
        uiView.scheduleMeasure()
    }

    final class Probe: UIView {
        var report: @MainActor (CGRect) -> Void = { _ in }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleMeasure()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleMeasure()
        }

        func scheduleMeasure() {
            Task { [weak self] in self?.measure() }
        }

        private func measure() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let scroll = view else { return }
            let frame = convert(bounds, to: scroll)
            report(frame)
        }
    }
}
