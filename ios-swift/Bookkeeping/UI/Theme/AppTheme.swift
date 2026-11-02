import SwiftUI
import UIKit

/// 「我的 › 显示 › 主题色」：按钮、导航栏和标签栏的选中项、开关、选中的分类等用的颜色。
/// 现成的用系统颜色，深色外观下系统自动调亮；也可以自己调（`stored(custom:)`）。
/// SwiftUI 部分在根视图上 `.tint`，UIKit 部分（卡包、首页顶部一行）跟着窗口的 `tintColor`。
/// 代码里要用主题色时写 `.tint`（`TintShapeStyle`），不要写 `Color.accentColor`（那是固定的蓝色）。
enum ThemeColor: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, green, mint, teal, cyan, brown, graphite

    static let key = "themeColor"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "蓝色"
        case .indigo: "靛蓝"
        case .purple: "紫色"
        case .pink: "粉色"
        case .red: "红色"
        case .orange: "橙色"
        case .green: "绿色"
        case .mint: "薄荷"
        case .teal: "水鸭"
        case .cyan: "青色"
        case .brown: "棕色"
        case .graphite: "石墨"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .brown: .systemBrown
        case .graphite: .systemGray
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// 存在 `key` 里的值：现成的颜色存名字，自己调的存 `#RRGGBB`
    static func uiColor(stored: String) -> UIColor {
        if let theme = ThemeColor(rawValue: stored) { return theme.uiColor }
        guard stored.hasPrefix("#"), let hex = UInt32(stored.dropFirst(), radix: 16) else { return ThemeColor.blue.uiColor }
        return UIColor(Color(hex: hex))
    }

    static func color(stored: String) -> Color { Color(uiColor: uiColor(stored: stored)) }

    static func title(stored: String) -> String { ThemeColor(rawValue: stored)?.title ?? "自定义" }

    static func stored(custom color: Color) -> String { String(format: "#%06X", color.hex) }

    /// UIKit 做的部分跟着窗口的 tintColor 变
    @MainActor static func applyToWindows() {
        let tint = uiColor(stored: UserDefaults.standard.string(forKey: key) ?? ThemeColor.blue.rawValue)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.tintColor = tint }
        }
    }
}

/// 颜色沿用 prototype 分支 `lib/theme/app_theme.dart`。
enum AppTheme {
    static let lightBg = Color(hex: 0xF2F1F6)
    static let darkBg = Color(hex: 0x000000)
    static let lightInk = Color(hex: 0x171719)
    static let darkInk = Color(hex: 0xF5F5F7)
    static let lightMuted = Color(hex: 0x85858A)
    static let darkMuted = Color(hex: 0x818187)
    static let lightSurface = Color(hex: 0xF5F5F7)
    static let darkSurface = Color(hex: 0x1C1C1E)
    static let lightLine = Color(hex: 0xECECEE)
    static let darkLine = Color(hex: 0x272729)
    static let lightIndicator = Color.black.opacity(0.08)
    static let darkIndicator = Color.white.opacity(0.16)
    static let debt = Color(hex: 0xE54D2E)
}

/// 根据当前配色取值的便捷集合。
struct Theme {
    let scheme: ColorScheme

    var isDark: Bool { scheme == .dark }
    var bg: Color { isDark ? AppTheme.darkBg : AppTheme.lightBg }
    var ink: Color { isDark ? AppTheme.darkInk : AppTheme.lightInk }
    var muted: Color { isDark ? AppTheme.darkMuted : AppTheme.lightMuted }
    var surface: Color { isDark ? AppTheme.darkSurface : AppTheme.lightSurface }
    /// 日间卡片底色比背景更白一层，保持原型的层级
    var card: Color { isDark ? AppTheme.darkSurface : Color.white }
    var line: Color { isDark ? Color(hex: 0x2C2C2E) : AppTheme.lightLine }
    var indicator: Color { isDark ? AppTheme.darkIndicator : AppTheme.lightIndicator }
    var glassTint: Color { Color.white.opacity(0.15) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// `0xRRGGBB`，超出 sRGB 的按边界算
    var hex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

/// 卡面配色：取自原型卡包的渐变与文字颜色。
struct CardPalette: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [UInt32]
    let text: UInt32
    let subtext: UInt32

    var gradient: LinearGradient {
        LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var textColor: Color { Color(hex: text) }
    var subtextColor: Color { Color(hex: subtext) }

    static let all: [CardPalette] = [
        CardPalette(id: "autumn-gold", name: "秋日金", colors: [0xFBE49D, 0xF6C869, 0xE5A83B], text: 0x6A4706, subtext: 0x987227),
        CardPalette(id: "jade", name: "翡翠绿", colors: [0x07C160, 0x049C4C], text: 0xFFFFFF, subtext: 0xE2F8EB),
        CardPalette(id: "ocean", name: "海蓝", colors: [0x1677FF, 0x0754CB], text: 0xFFFFFF, subtext: 0xD3E7FF),
        CardPalette(id: "midnight", name: "曜石黑", colors: [0x262629, 0x171719, 0x0F0F11], text: 0xFFFFFF, subtext: 0xA5A5AB),
        CardPalette(id: "lime", name: "青柠", colors: [0x9FE870, 0x86D654], text: 0x163300, subtext: 0x2E5E0B),
        CardPalette(id: "forest", name: "森绿", colors: [0x009944, 0x007A33], text: 0xFFFFFF, subtext: 0xDCFCE7),
        CardPalette(id: "lagoon", name: "湖光", colors: [0x0093E9, 0x80D0C7], text: 0xFFFFFF, subtext: 0xE0F7FA),
        CardPalette(id: "graphite-gold", name: "石墨金", colors: [0x2B2B30, 0x18181A], text: 0xF2E2C4, subtext: 0x9E9585),
        CardPalette(id: "violet", name: "紫罗兰", colors: [0x660874, 0x3B2F7E], text: 0xFFFFFF, subtext: 0xE9D8FD),
        CardPalette(id: "aurora", name: "极光", colors: [0x38BDF8, 0x6366F1, 0xF472B6], text: 0xFFFFFF, subtext: 0xF0F9FF),
        CardPalette(id: "crimson", name: "绯红", colors: [0xD0263A, 0x8E0C22], text: 0xFFFFFF, subtext: 0xFFE4E6),
        CardPalette(id: "sunset", name: "落日", colors: [0xFF8A4C, 0xE5484D], text: 0xFFFFFF, subtext: 0xFFE8DD),
    ]

    static func named(_ id: String) -> CardPalette { all.first { $0.id == id } ?? all[2] }
}

/// 卡片尺寸：卡包和详情用同一个尺寸，转场时只做平移、缩放等变换，不改变布局。
enum AppLayout {
    static let cardInset: CGFloat = 16
    /// 卡片宽高比（接近实体银行卡）
    static let cardAspect: CGFloat = 295.0 / 186.0
    static let cardCornerRadius: CGFloat = 20
    /// 卡包里每张卡露出的高度（按卡宽 295 时为 52）
    static let peekRatio: CGFloat = 52.0 / 295.0
    /// 详情页卡片顶端：顶部按钮行下方
    static let detailTop: CGFloat = 54
    /// 首页、统计页顶部一行下面到列表的距离
    static let topBarBottom: CGFloat = 6

    static func cardWidth(_ viewport: CGFloat) -> CGFloat { max(1, viewport - cardInset * 2) }
    static func cardHeight(_ viewport: CGFloat) -> CGFloat { cardWidth(viewport) / cardAspect }
    static func peek(_ viewport: CGFloat) -> CGFloat { cardWidth(viewport) * peekRatio }
}
