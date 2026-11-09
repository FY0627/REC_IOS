import SwiftUI
import UIKit

/// 对齐参考线：盖在所有标签页上面的三条横线，位置是首页量出来的（`FirstBoxLayout`），资产页的「合计」和净资产卡按它排。
/// 红线：分组标题文字的底边；蓝线：第一个白框的顶端；绿线：白框里第一行字的顶端（白框顶端加上格子的边距）。
/// 在首页看线和首页自己的字、白框对不对得上（量得对不对），在资产页看「合计」和卡片对不对得上（排得对不对）。
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
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
