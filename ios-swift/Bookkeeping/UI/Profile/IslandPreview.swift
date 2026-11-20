import SwiftUI
import UIKit
import BKModel

/// 「我的 › 通知 › 灵动岛」打开时下面的演示：照岛上第 1 页画（ADR 0024），没有底色，岛自己浮在设置项下面。
/// 尺寸照 `CategoryActivity` 里的 `IslandLayout`：岛宽 371、高 10 + 32 + 8 + 92 + 16 = 158，
/// 顶上一行商户、金额，摄像头在正中，下面一行 5 个按钮（4 个分类 +「全部」）在两行的高度里上下居中。
/// 按真的尺寸画好再整体缩到这一行的宽度，元素之间的比例和真机一样。
/// 没有灵动岛的手机画待分类的提醒横幅（`ReminderCard`）。
/// 岛是黑色的；深色模式下页面也是黑的，岛换成深灰，跟着外观实时换
struct IslandPreview: View {
    let hasIsland: Bool

    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue

    private var tint: Color { ThemeColor.color(stored: themeColor) }
    private var size: CGSize { hasIsland ? IslandShape.island : IslandShape.reminder }

    var body: some View {
        Color.clear
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    shape
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(geo.size.width / size.width, anchor: .topLeading)
                }
            }
            .frame(maxWidth: size.width)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("效果演示"))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var shape: some View {
        if hasIsland {
            island
                .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: IslandShape.islandCorner, style: .continuous))
        } else {
            reminder
                .background(IslandShape.fill, in: RoundedRectangle(cornerRadius: IslandShape.reminderCorner, style: .continuous))
        }
    }

    // MARK: 灵动岛

    private var island: some View {
        VStack(spacing: IslandShape.systemGap) {
            HStack {
                Text(verbatim: L("便利店"))
                Spacer(minLength: IslandShape.cameraWidth + 16)
                Text(verbatim: Fmt.money(3200, .cny)).monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(height: IslandShape.headerLine)
            .padding(.horizontal, IslandShape.headerInset)
            .padding(.top, IslandShape.header - IslandShape.headerLine)
            HStack(spacing: IslandShape.columnSpacing) {
                ForEach(IslandShape.cells, id: \.title) { cell($0) }
            }
            .frame(maxWidth: .infinity, minHeight: IslandShape.grid, maxHeight: IslandShape.grid)
        }
        .padding(.horizontal, IslandShape.sideMargin)
        .padding(.top, IslandShape.topMargin)
        .padding(.bottom, IslandShape.bottomMargin)
        .frame(width: IslandShape.island.width, height: IslandShape.island.height, alignment: .top)
        .overlay(alignment: .top) { camera }
        .dynamicTypeSize(.large)
    }

    /// 摄像头：岛正中顶上那一块，右边是镜头
    private var camera: some View {
        Circle()
            .fill(Color(white: 0.09))
            .overlay { Circle().strokeBorder(Color(white: 0.2), lineWidth: 1) }
            .frame(width: IslandShape.lens, height: IslandShape.lens)
            .offset(x: IslandShape.lensOffset, y: (IslandShape.cameraHeight - IslandShape.lens) / 2)
    }

    private func cell(_ cell: IslandShape.Cell) -> some View {
        VStack(spacing: 2) {
            Image(systemName: cell.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(cell.isAll ? Color.white : tint)
                .frame(width: IslandShape.circle, height: IslandShape.circle)
                .background(cell.isAll ? Color.white.opacity(0.14) : tint.opacity(0.22), in: Circle())
            Text(verbatim: cell.title.loc)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: IslandShape.cell.width, height: IslandShape.cell.height)
    }

    // MARK: 没有灵动岛：提醒横幅

    private var reminder: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Image(systemName: "receipt.fill")
                .font(.system(size: 42))
                .foregroundStyle(tint)
                .frame(width: IslandShape.badge, height: IslandShape.badge)
            VStack(alignment: .leading, spacing: 1) {
                Text("刚刚记了一笔")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("待分类")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Circle()
                .strokeBorder(tint, lineWidth: 5.5)
                .frame(width: IslandShape.badge, height: IslandShape.badge)
                .overlay {
                    Text(verbatim: "1")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                }
        }
        .padding(IslandShape.lockMargin)
        .frame(width: IslandShape.reminder.width, height: IslandShape.reminder.height)
        .dynamicTypeSize(.large)
    }
}

/// 和 `IslandLayout`（小组件扩展里）一样的数，App 这边拿不到那个文件，抄一份
private enum IslandShape {
    struct Cell {
        let title: String
        let symbol: String
        var isAll = false
    }

    /// 第 1 页：常用的 4 个分类（默认分类里的）和「全部」
    static let cells = [
        Cell(title: "饮食", symbol: "fork.knife"),
        Cell(title: "交通", symbol: "car"),
        Cell(title: "日用品", symbol: "basket"),
        Cell(title: "娱乐", symbol: "gamecontroller"),
        Cell(title: "全部", symbol: LiveCategoryPicker.allSymbol, isAll: true),
    ]

    /// 岛：深色模式的页面是黑的，换成深灰才看得见
    static let fill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .black })

    static let cell = CGSize(width: 60, height: 44)
    static let circle: CGFloat = 28
    static let columnSpacing: CGFloat = 4
    static let grid: CGFloat = cell.height * 2 + 4
    static let header: CGFloat = 32
    static let headerLine: CGFloat = 28
    static let headerInset: CGFloat = 10
    static let sideMargin: CGFloat = 19
    static let topMargin: CGFloat = 10
    static let bottomMargin: CGFloat = 16
    /// 摄像头那一行和按钮之间系统空的
    static let systemGap: CGFloat = 8
    static let island = CGSize(width: 371, height: topMargin + header + systemGap + grid + bottomMargin)
    /// 岛的圆角（真机截图量的黑边圆角）
    static let islandCorner: CGFloat = 48
    /// 摄像头（收起的岛）多宽多高；镜头在它右半边
    static let cameraWidth: CGFloat = 126
    static let cameraHeight: CGFloat = 37
    static let lens: CGFloat = 12
    static let lensOffset: CGFloat = 40

    static let badge: CGFloat = 56
    static let lockMargin: CGFloat = 14
    static let reminder = CGSize(width: 371, height: badge + lockMargin * 2)
    static let reminderCorner: CGFloat = 24
}
