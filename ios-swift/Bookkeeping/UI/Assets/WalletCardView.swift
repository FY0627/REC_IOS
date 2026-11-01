import SwiftUI
import BKModel

/// 卡面：配色渐变时有银行圆标、名称与卡类型、余额、尾号；自定义图片时只有带描边的余额，位置可调（默认右上角）。尺寸由外部 frame 决定。
///
/// 渲染开销按 Apple 的建议压低：
/// - 阴影只画在一个圆角矩形上（形状阴影），不对含文字的整张卡做阴影，避免离屏渲染；
/// - 不对整张卡 clip：渐变直接填充圆角矩形，图片的圆角画在位图里（`CardFaceImages`）；
/// - 卡面不依赖动画进度，转场时外部只改变换（位移、缩放、旋转、透明度），卡面本身不重新计算。
struct WalletCardView: View {
    let account: Account
    let balanceText: String
    /// 编辑卡面时用：拖动金额要知道它现在多大
    var amountSize: Binding<CGSize>? = nil

    /// 图片上的默认文字（白字黑边，在大多数照片上都清楚）
    static let photoTextColor: UInt32 = 0xFFFFFF
    static let photoOutlineColor: UInt32 = 0x000000
    /// 卡面内容到卡片边缘的距离
    private static let padding = CGSize(width: 18, height: 14)
    private static let outlineWidth = 1.2
    private static let outlineDirections = (0..<8).map { CGPoint(x: cos(Double($0) * .pi / 4), y: sin(Double($0) * .pi / 4)) }
    fileprivate static let shape = RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius, style: .continuous)

    /// 金额在卡片上能移动的距离：卡片去掉内边距和金额自己的大小
    static func amountTravel(card: CGSize, amount: CGSize) -> CGSize {
        CGSize(
            width: max(1, card.width - padding.width * 2 - amount.width),
            height: max(1, card.height - padding.height * 2 - amount.height)
        )
    }

    var body: some View {
        let palette = CardPalette.named(account.paletteID)
        let flags = PerfFlags.shared
        face(palette)
            .modifier(CardRasterization(enabled: flags.rasterizeCards))
            .background {
                if flags.cardShadows {
                    Self.shape
                        .fill(Color(hex: palette.colors.last ?? 0x000000))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.spokenTitle)，\(balanceText)")
    }

    private func face(_ palette: CardPalette) -> some View {
        let style = account.face
        let text = style.textColor.map { Color(hex: $0) } ?? (style.imageID == nil ? palette.textColor : Color(hex: Self.photoTextColor))
        return Group {
            if style.imageID == nil {
                details(palette, text: text)
            } else {
                AmountPlacement(x: style.amountX, y: style.amountY) { photoBalance }
            }
        }
        .padding(.horizontal, Self.padding.width)
        .padding(.vertical, Self.padding.height)
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { CardBackground(palette: palette, imageID: style.imageID) }
    }

    private var balance: some View {
        Text(balanceText)
            .font(.system(size: 14 * account.face.textScale, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// 描边：往八个方向各错开一点画一遍，金额盖在上面，再合成一张小位图，滚动时不用一层一层叠 9 遍字
    private var photoBalance: some View {
        let width = Self.outlineWidth * account.face.textScale
        let outline = Color(hex: account.face.outlineColor ?? Self.photoOutlineColor)
        return ZStack {
            ForEach(Self.outlineDirections.indices, id: \.self) { index in
                balance
                    .foregroundStyle(outline)
                    .offset(x: Self.outlineDirections[index].x * width, y: Self.outlineDirections[index].y * width)
            }
            balance
        }
        .modifier(AmountFlattening(enabled: PerfFlags.shared.flattenCardAmount))
        .modifier(AmountSizeReport(size: amountSize))
    }

    private func details(_ palette: CardPalette, text: Color) -> some View {
        let style = account.face
        let s = style.textScale
        let subtext = style.textColor == nil ? palette.subtextColor : text.opacity(0.75)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(text.opacity(0.15))
                        .frame(width: 30 * s, height: 30 * s)
                        .overlay(Text(Self.badge(account)).font(.system(size: 14 * s, weight: .bold)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.name).font(.system(size: 14 * s, weight: .bold)).lineLimit(1)
                        Text(account.isCard ? "\(account.bankName) · \(account.cardType.displayName)" : account.cardType.displayName)
                            .font(.system(size: 11 * s, weight: .medium))
                            .foregroundStyle(subtext)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "wave.3.right").font(.system(size: 13 * s)).opacity(0.8)
                    balance
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                if account.isCard {
                    Text("•••• \(account.last4)").font(.system(size: 15 * s, weight: .semibold)).tracking(1.2)
                } else {
                    // 现金、电子钱包没有卡号
                    Image(systemName: account.cardType.symbolName).font(.system(size: 17 * s, weight: .semibold)).opacity(0.85)
                }
                Spacer()
                Text(Self.currencyLabel(account)).font(.system(size: 12 * s, weight: .bold)).italic().opacity(0.8)
            }
        }
    }

    /// 圆标里的字：列表里的银行用它的简称（「中国工商银行」写「工」），自己填的银行用名称的第一个字
    static func badge(_ account: Account) -> String {
        BankCatalog.entry(id: account.bankID)?.badge ?? String(account.bankName.prefix(1))
    }

    /// 单币种显示币种代码；多币种显示主币种和其他币种的数量，例如「HKD +2」。
    static func currencyLabel(_ account: Account) -> String {
        account.isMultiCurrency ? "\(account.currency.rawValue) +\(account.extraCurrencies.count)" : account.currency.rawValue
    }

}

/// 卡面背景。单独一个视图：一张图解码好时，所有卡的这一层重新计算，卡面上的文字不跟着算。
/// 自定义图片在后台解码完成之前先显示配色渐变。
private struct CardBackground: View {
    let palette: CardPalette
    let imageID: String?

    var body: some View {
        if let imageID, let image = CardFaceImages.shared.image(imageID) {
            // 位图和卡片一样大，圆角已经画在里面
            Image(uiImage: image)
                .resizable()
                .modifier(CardPhotoClip(enabled: PerfFlags.shared.clipCardPhotos))
        } else {
            WalletCardView.shape.fill(palette.gradient)
        }
    }
}

/// 单变量开关：图片再用遮罩裁一次圆角（原来的做法，留着对照）。
private struct CardPhotoClip: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.clipShape(WalletCardView.shape) } else { content }
    }
}

/// 单变量开关：金额和描边合成一张小位图。位图只画得到自己的范围，四周多留一点给描边。
private struct AmountFlattening: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.padding(3).drawingGroup().padding(-3) } else { content }
    }
}

/// 只有编辑卡面时才量金额的大小
private struct AmountSizeReport: ViewModifier {
    let size: Binding<CGSize>?
    func body(content: Content) -> some View {
        if let size {
            content.onGeometryChange(for: CGSize.self) { $0.size } action: { size.wrappedValue = $0 }
        } else {
            content
        }
    }
}

/// 按比例摆放金额：0 贴左 / 上，1 贴右 / 下，金额多长都不会出卡片。
private struct AmountPlacement: Layout {
    let x: Double
    let y: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let amount = subviews.first else { return }
        let fit = ProposedViewSize(width: bounds.width, height: nil)
        let size = amount.sizeThatFits(fit)
        amount.place(
            at: CGPoint(x: bounds.minX + (bounds.width - size.width) * x, y: bounds.minY + (bounds.height - size.height) * y),
            anchor: .topLeading,
            proposal: fit
        )
    }
}

/// 单变量开关：卡面是否先合成为一张离屏位图。
private struct CardRasterization: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.drawingGroup() } else { content }
    }
}

extension AccountBalances {
    /// 卡面上显示一个币种的余额：主币种有余额就用主币种，否则用第一个有余额的币种。
    var cardText: String { display?.cardText ?? "余额未知" }
}

extension AccountBalanceSummary {
    /// 卡面上显示的余额：从你填写的初始余额推算；没填时显示「余额未知」，不用部分流水冒充。
    var cardText: String {
        guard let derived = ledgerDerivedMinor else { return "余额未知" }
        return Fmt.money(derived, currency)
    }
}
