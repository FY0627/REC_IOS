import SwiftUI

/// 「我的 › 显示 › 图标」：三个桌面图标直接排出来点选，一眼看得出哪个浅色、哪个深色。
/// 只放图标不写名字；跟随系统的那个左上半浅色、右下半深色。
struct AppIconPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("图标", systemImage: "app")
            HStack(spacing: 0) {
                ForEach(AppearanceMode.allCases) { mode in
                    let selected = selection == mode.rawValue
                    // 只放图标，不写名字：看图标就知道是哪个（名字用 `L` 算，换语言时「我的」不重建，会停在原来的语言）
                    Button { selection = mode.rawValue } label: {
                        AppIconPreview(mode: mode)
                            .frame(width: 60, height: 60)
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 2)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 桌面图标的样子：用 `AppIcon*.icon` 的图层（资源目录 `IconLayers` 里的同一套 SVG）和 `icon.json` 里的颜色画平面版，
/// 每组图层下面一点阴影（系统画的 Liquid Glass 高光、半透明这里不画）。改图标的图形或颜色时这里一起改
struct AppIconPreview: View {
    let mode: AppearanceMode
    /// 60 点大的图标用 13.5；别的大小按比例给
    var cornerRadius: CGFloat = 13.5

    var body: some View {
        switch mode {
        case .light: face(.light)
        case .dark: face(.dark)
        case .system: face(.light).overlay { face(.dark).mask(LowerRightHalf()) }
        }
    }

    private func face(_ palette: Palette) -> some View {
        ZStack {
            palette.background
            group([("IconLayerBack", palette.back)])
            group([
                ("IconLayerCard", palette.card), ("IconLayerStripe", palette.stripe), ("IconLayerReceipts", palette.receipts),
                ("IconLayerLines", palette.lines), ("IconLayerLettuce", palette.lettuce),
            ])
            group([("IconLayerFront", palette.front)])
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 浅色图标放在白色的列表上也看得出边
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    /// 从下往上叠的一组图层
    private func group(_ layers: [(String, Color)]) -> some View {
        ZStack {
            ForEach(layers, id: \.0) { layer in
                Image(layer.0).resizable().renderingMode(.template).foregroundStyle(layer.1)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 0.6, y: 0.6)
    }

    private struct Palette {
        let background, back, card, stripe, receipts, lines, lettuce, front: Color

        static let light = Palette(
            background: rgb(1, 1, 1), back: rgb(0.87843, 0.6, 0.00392), card: rgb(0.17255, 0.49804, 0.71765),
            stripe: rgb(0.10588, 0.32157, 0.46275), receipts: rgb(1, 1, 1), lines: rgb(0.70196, 0.70196, 0.70196),
            lettuce: rgb(0.19216, 0.79608, 0.43922), front: rgb(1, 0.77255, 0.16863)
        )
        static let dark = Palette(
            background: rgb(0.07843, 0.07843, 0.0902), back: rgb(0.92157, 0.64314, 0.10196), card: rgb(0.22745, 0.56078, 0.8),
            stripe: rgb(0.14118, 0.39216, 0.56078), receipts: rgb(0.94902, 0.94902, 0.96863), lines: rgb(0.60392, 0.60392, 0.62353),
            lettuce: rgb(0.22745, 0.83922, 0.48627), front: rgb(1, 0.80392, 0.27059)
        )

        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }
    }
}

/// 右下半个三角：跟随系统的图标右下半边画深色的
private struct LowerRightHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
