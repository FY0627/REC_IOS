import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import BKModel

@main
struct CategoryActivityBundle: WidgetBundle {
    var body: some Widget {
        CategoryActivityWidget()
    }
}

/// 灵动岛选分类（ADR 0024）：自动记账记上一笔没分类的支出或收入后，App 开启这个实时活动，在岛上和锁屏上选分类。
///
/// - 展开（长按岛展开）：摄像头两边是顶上一行（第 1 页商户，第 2、3 页返回和标题；右边金额），下面是按钮，一行 5 个；
/// - 刚开启：App 不在前台时新开启的，系统有时先自己展开约 3 秒，App 关不掉。这几秒展开的是一张提醒（`ContentState.notice`），
///   照 AirPods 连上时的样子：左边主题色收据图标，摄像头下面灰色「刚刚记了一笔」、白色「待分类」，右边主题色圆环里是待分类的笔数。
///   不放商户、金额（别人可能看到），摄像头旁边也不放标签图标；单点打开 App 这一笔的选分类面板。几秒后 App 更新一次去掉提醒，长按展开才是按钮；
/// - 按钮：分类是主题色的圆和图标，「全部」「更多」是白色的圆，字在圆下面；
/// - 选好：岛的大小不变，顶上的商户、金额留着；按钮那一块换成一行：左边主题色圆里是选中的分类图标，中间灰色「已分类」、白色分类名，
///   右边主题色圆圈。一步一次更新（`ChosenStep`）：按钮淡出 → 这一行从下往上出来 → 系统按时间接着画：圆圈从 12 点顺时针一圈、
///   圆圈里从左往右画出对勾（像面容 ID 认出来，`ChosenCheck`）→ 停一下，最后一笔就收起灵动岛，还有下一笔就直接换过去；
/// - 收起：只有左边的分类图标（还没选是统一的标签图标），右边空着、不放金额；minimal 只放图标；
/// - 锁屏：黑色卡片，同样的三页和按钮；没有灵动岛的手机只放提醒（`ContentState.reminderOnly`），这张卡片也是屏幕上方弹出的横幅；
/// - 换页、选好、换下一笔：整页上下滚过去，返回时反过来（`IslandMotion`）。
///
/// 按钮都是 `LiveActivityIntent`，在 App 进程里运行，不打开 App。单点岛或卡片打开 App 里这一笔的选分类面板。
/// 扩展只照着内容显示（`CategoryActivityAttributes.ContentState`），不读账本、不翻译
struct CategoryActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CategoryActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        } dynamicIsland: { context in
            // 刚开启：展开的是提醒。过了换按钮的时间（`staleDate`）App 还没换、系统又刚好重画时放按钮
            let state = context.state
            let notice = context.isStale ? nil : state.notice
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if notice != nil {
                        NoticeIcon(tint: state.tintColor)
                            .badgeSlot(.leading)
                    } else {
                        IslandLeading(state: state)
                            .islandSwap(state.headerKey, back: state.isBack)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let notice {
                        NoticeCount(count: notice.count, tint: state.tintColor)
                            .badgeSlot(.trailing)
                    } else {
                        IslandTrailing(state: state)
                            .islandSwap(state.amountKey, back: state.isBack)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let notice {
                        IslandBadgeText(caption: notice.caption, title: notice.title)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 选好以后也一直在：岛的大小不变
                    if notice == nil {
                        IslandBottom(state: state)
                            .islandSwap(state.bottomKey, back: state.isBack)
                            .transition(IslandMotion.page(back: state.isBack))
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(context.state.tintColor)
            } compactTrailing: {
                // 平时不放金额，只留左边的图标
                EmptyView()
            } minimal: {
                Image(systemName: context.state.chosen?.symbol ?? LiveCategoryPicker.unpickedSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(context.state.tintColor)
            }
            .contentMargins(.horizontal, IslandLayout.sideMargin, for: .expanded)
            .contentMargins(.top, IslandLayout.topMargin, for: .expanded)
            .contentMargins(.bottom, IslandLayout.bottomMargin, for: .expanded)
            .keylineTint(context.state.tintColor)
            .widgetURL(CategoryActivityLink.url(recordID: context.state.recordID))
        }
    }
}

/// Apple 规范：展开和锁屏宽 371 点（Pro Max、Plus 408），高 84–160 点，超出的部分系统直接切掉。
/// 真机截图量出来（展开）：
/// - 只显示离黑边约 13 点以内的部分，四个角是半径约 35 的圆角（黑边的圆角约 48），外面那一圈黑边上的东西被切掉；
/// - 摄像头那一行和下面的按钮之间系统还要空约 8 点。
/// 按钮 60 × 44（圆 28、图标 14、字 12），一行 5 个、间隔 4，宽 316，两边的按钮离黑边远一些，第二行的字不碰下面两个角；两行高 44 + 4 + 44 = 92。
/// 上边距 10 + 顶上一行 32 + 系统 8 + 92 + 下边距 16 ≈ 158：第二行的字离黑边约 18 点。
/// 顶上一行的东西放在下面 28 点里、左右各往里缩 10 点，返回、商户和金额不碰上面两个角。
/// 锁屏没有摄像头：10 + 30 + 6 + 92 + 10 = 148
///
/// 每一页都占两行按钮的高度：第 1 页只有一行时上下居中，空出来的地方留白。
/// 以前第 1 页一行、「全部」两行，换页时岛跟着变高变矮，系统缩放岛时整块重排，金额也跟着动，动画乱；现在选分类的几页岛的大小不变。
/// 选好时岛的大小也不变（真机上岛一变大小，系统整个变形，内容被切）：只把按钮换成选好的一行（`ChosenStep`）
enum IslandLayout {
    static let cell = CGSize(width: 60, height: 44)
    static let circle: CGFloat = 28
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    /// 按钮区固定的高度：一屏最多的行数（两行）
    static let grid: CGFloat = {
        let rows = CGFloat(LiveCategoryPicker.perScreen / LiveCategoryPicker.perRow)
        return cell.height * rows + rowSpacing * (rows - 1)
    }()
    /// 顶上一行占的高度；里面的东西放在下面 `headerLine` 里
    static let header: CGFloat = 32
    static let headerLine: CGFloat = 28
    static let headerInset: CGFloat = 10
    static let backCircle: CGFloat = 24
    static let sideMargin: CGFloat = 19
    static let topMargin: CGFloat = 10
    static let bottomMargin: CGFloat = 16
    /// 摄像头两边只有一行的字和金额用同一个字号
    static let lineFont = Font.headline
    /// 字号跟系统走，但不超过这一档：再大两行按钮放不进 160 点
    static let largestType: DynamicTypeSize = .large
    /// 提醒和选好：左边的图标、右边的圆环有多大。做满摄像头两边（HIG：内容紧贴原深感摄像头，四周不留太多空）：
    /// 真机截图量的（9cde1b8，圆 44）：圆心离岛边 41、上沿离岛顶 31、下沿离岛顶 74.5，两行字的下沿离岛顶 76，岛高约 95。
    /// 放大到 56、不往里收：圆心离岛边约 44，和岛 44 点的圆角同心（圆到岛边一圈一样宽）；
    /// 上沿离岛顶约 20，到摄像头旁边；下沿约 76，和两行字的下沿对齐。岛不变高（两行字那边更高）
    static let noticeBadge: CGFloat = 56
    /// 图标和圆环从顶上的边距往下放多少：上沿离岛顶约 10 + 10 = 20
    static let noticeDrop: CGFloat = 10
    /// 中间两行字离左边的图标再远一点：真机上只隔了约 8 点，太挤
    static let badgeTextGap: CGFloat = 10
    /// 选好的样子出来时从下面多远上来
    static let revealRise: CGFloat = 16
    /// 锁屏卡片的边距：苹果规范里锁屏实时活动的标准边距是 14 点
    static let lockMargin: CGFloat = 14
    /// 提醒的圆环的线宽
    static let ringLine: CGFloat = 5.5
    /// 选好的一行：左边的图标圆、右边的圆圈多大。离岛边 19 + 8 = 27，和按钮一样；在按钮那块的 92 里上下居中
    static let chosenBadge: CGFloat = 60
    static let chosenInset: CGFloat = 8
    /// 选好的圆圈：线宽 5，在系统圆环（线宽是直径的十分之一、外沿贴着框）的正中间，里外各比它窄 0.5 点（`ChosenCheck`）
    static let chosenRing: CGFloat = 5
    static let chosenRingInset: CGFloat = chosenBadge / 20
    /// 选好的一行：图标和字之间
    static let chosenGap: CGFloat = 14
    /// 选好时圆圈里的对勾：边长和线宽
    static let check: CGFloat = 32
    static let checkLine: CGFloat = 3.8
}

extension CategoryActivityAttributes.ContentState {
    /// App 的主题色（`ThemeColor`）；以前开的活动没写，用蓝色
    var tintColor: Color {
        switch tint {
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "brown": .brown
        case "graphite": .gray
        default: .blue
        }
    }
}

extension CategoryActivityAttributes.ContentState {
    /// 岛下面那一块、锁屏卡片下面的按钮：换页、选好、换下一笔时变。选好以后的几步不算，一直是同一个（只改位置、透明度系统才有动画）
    var bottomKey: String { "\(recordID)|\(screen.page.token)|\(chosen?.id ?? "")" }

    /// 左边：返回和标题跟着页变；选好了回到商户（第 1 页的样子）；换下一笔时换
    var headerKey: String {
        if chosen == nil, screen.back != nil { return "\(recordID)|\(screen.page.token)" }
        return recordID
    }

    /// 右边金额：换下一笔时换
    var amountKey: String { recordID }
}

/// 换页、选好、换下一笔：像翻桌面那样整页滚过去，只是上下滚。
/// 往前（点进去、「更多」、选好、下一笔）旧的往上滚走、新的从下面上来；返回反过来，新的从上面下来。
/// 系统让旧内容按它自己身上的方向离开，所以方向变了 App 先单独更新一次方向，再换内容（`LiveCategoryActivity.present`）。
/// 系统给小组件和实时活动的动画最长 2 秒；常亮显示（Always On）时系统不做动画
enum IslandMotion {
    static let scroll: Animation = .smooth(duration: 0.35)

    static func page(back: Bool) -> AnyTransition {
        .push(from: back ? .top : .bottom)
    }
}

extension View {
    /// `key` 变了就整页滚过去；只在自己的范围里滚，滚出去的部分切掉，不压到别的东西上
    func islandSwap<Key: Hashable>(_ key: Key, back: Bool) -> some View {
        ZStack {
            self.id(key).transition(IslandMotion.page(back: back))
        }
        .clipped()
        .animation(IslandMotion.scroll, value: key)
    }

    /// 选好的一行：放好那一步看不见、在下面一点；下一步出来。
    /// 从放好到出来一直是同一个视图，只改位置和透明度：系统只对这个放动画（新加进来的只会淡入）
    func chosenReveal(_ step: CategoryActivityAttributes.ChosenStep) -> some View {
        opacity(step >= .showing ? 1 : 0)
            .offset(y: step <= .placed ? IslandLayout.revealRise : 0)
            .animation(IslandMotion.scroll, value: step)
    }

    /// 提醒左边的图标、右边的圆环：靠边（和岛的圆角同心，见 `noticeBadge`），往下放，下沿和中间两行字的下沿对齐
    func badgeSlot(_ edge: HorizontalEdge) -> some View {
        frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .padding(.top, IslandLayout.noticeDrop)
    }

    /// 岛上顶上一行：占 32 高，东西放在下面 28 里，再往岛中间缩 10 点，不碰岛的上面两个角
    func islandHeader(_ edge: HorizontalEdge) -> some View {
        let side: Edge.Set = edge == .leading ? .leading : .trailing
        return frame(height: IslandLayout.headerLine, alignment: .center)
            .padding(side, IslandLayout.headerInset)
            .padding(.top, IslandLayout.header - IslandLayout.headerLine)
    }
}

/// 展开的岛左边：顶上一行（`HeaderLeading`）；选好以后是商户
struct IslandLeading: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        HeaderLeading(state: state, inline: false)
            .islandHeader(.leading)
    }
}

/// 展开的岛右边：金额；选好以后留着
struct IslandTrailing: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        AmountText(amount: state.amount)
            .islandHeader(.trailing)
    }
}

/// 第 1 页：岛上只有商户（没有商户是账户），锁屏是商户和账户；第 2、3 页：返回和标题。选好了回到第 1 页的样子（商户留着）。
/// 岛上放不下两行：两行的字顶到岛上面的黑边，会被切掉。
/// 这一行的字和右边的金额一样大（`IslandLayout.lineFont`），锁屏上商户后面的账户小一号
struct HeaderLeading: View {
    let state: CategoryActivityAttributes.ContentState
    let inline: Bool

    var body: some View {
        if state.chosen == nil, let back = state.screen.back {
            Button(intent: ShowLiveCategoryPageIntent(recordID: state.recordID, page: back)) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: IslandLayout.backCircle, height: IslandLayout.backCircle)
                        .background(Color.white.opacity(0.14), in: Circle())
                    if let title = state.screen.title {
                        Text(title)
                            .font(IslandLayout.lineFont)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: IslandLayout.headerLine, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if inline, let merchant = state.merchant {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(merchant)
                    .font(IslandLayout.lineFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.account)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        } else {
            Text(state.merchant ?? state.account)
                .font(IslandLayout.lineFont)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

/// 刚开启时展开的岛（照 AirPods 连上时的样子）的左边：主题色收据图标，比摄像头低一点，和中间两行字、右边圆环对齐。
/// 单点整个岛打开 App 这一笔的选分类面板（`widgetURL`）
struct NoticeIcon: View {
    let tint: Color

    var body: some View {
        Image(systemName: "receipt.fill")
            .font(.system(size: 42))
            .foregroundStyle(tint)
            .frame(width: IslandLayout.noticeBadge, height: IslandLayout.noticeBadge)
    }
}

/// 提醒和选好的岛的中间（摄像头下面）：上面灰色小字，下面白色大字，靠左。提醒是「刚刚记了一笔」「待分类」，选好是「已分类」和分类名
struct BadgeText: View {
    let caption: String
    let title: String
    /// 选好的一行：分类名大一号（`title2`），把中间撑满
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(title)
                .font((large ? Font.title2 : .title3).weight(.semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...IslandLayout.largestType)
    }
}

/// 摄像头下面的两行字：离左边的图标远一点（`badgeTextGap`）
struct IslandBadgeText: View {
    let caption: String
    let title: String

    var body: some View {
        BadgeText(caption: caption, title: title)
            .padding(.leading, IslandLayout.badgeTextGap)
    }
}

/// 刚开启时展开的岛的右边：主题色圆环，里面是待分类的笔数
struct NoticeCount: View {
    let count: Int
    let tint: Color

    var body: some View {
        Circle()
            .strokeBorder(tint, lineWidth: IslandLayout.ringLine)
            .frame(width: IslandLayout.noticeBadge, height: IslandLayout.noticeBadge)
            .overlay {
                Text(verbatim: String(count))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(8)
            }
    }
}

/// 选好的一行左边：主题色圆里是白色的分类图标
struct ChosenIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: IslandLayout.chosenBadge, height: IslandLayout.chosenBadge)
            .background(tint, in: Circle())
    }
}

/// 选好的一行：左边分类图标，中间「已分类」和分类名，右边圆圈和对勾。岛上和锁屏卡片一样
struct ChosenRow: View {
    let state: CategoryActivityAttributes.ContentState
    let chosen: LiveCategoryPicker.Option

    var body: some View {
        HStack(spacing: IslandLayout.chosenGap) {
            ChosenIcon(symbol: chosen.symbol, tint: state.tintColor)
            BadgeText(caption: state.chosenCaption ?? "", title: chosen.name, large: true)
            ChosenCheck(ring: state.ringRange, check: state.checkRange, tint: state.tintColor)
        }
        .padding(.horizontal, IslandLayout.chosenInset)
        .frame(maxWidth: .infinity, minHeight: IslandLayout.grid, maxHeight: IslandLayout.grid)
    }
}

/// 选好的一行右边：像面容 ID 认出来那样，主题色圆圈从 12 点顺时针画一圈，接着在里面从左往右画出对勾。
/// 实时活动里只有按时间走的计时文字和进度条系统会自己一帧一帧往前画；别的改动都要等下一次更新，形状也不会在两次更新之间变
/// （SF Symbols 的 Draw On、`trim` 改终点、转半平面真机上都是直接出现）。
/// 直接放系统的圆环（`ProgressView(timerInterval:)` 圆形的）真机上看到：底下有一圈浅色的底；画满的圆是两段，淡出时 12 点、6 点的接头比别处亮；
/// 整块往上移时它不跟着移。所以圆圈和对勾都是自己画好的、一直在，系统按时间画的进度条只当遮罩把它们露出来（`TimedReveal`）：
/// 遮罩只看透明度，圆圈是自己画的一笔，没有接头；对勾的遮罩是横条，从左往右。
/// 真机录屏逐帧看到：画完以后 App 每发一次更新，按时间画的进度条都会暗一下再亮回来（遮罩跟着暗，圆圈和对勾闪一下），
/// 不管这次改的是什么；`transition(.identity)`、`animation(nil)` 在实时活动里也关不掉。
/// 所以画完以后不再更新：停一下，最后一笔直接收起灵动岛，还有下一笔就直接整页换过去（`LiveCategoryActivity.pick`）。
/// 系统的圆环线宽是直径的十分之一、外沿贴着框（真机截图量的）；自己画的圆圈在它中间、里外各窄 0.5 点，
/// 遮罩边上的半透明碰不到它，画满时和没有遮罩一样粗
struct ChosenCheck: View {
    /// 圆圈从空画到满的时间（`ContentState.ringRange`）
    let ring: ClosedRange<Date>
    /// 对勾画出来的时间（`ContentState.checkRange`）
    let check: ClosedRange<Date>
    let tint: Color

    var body: some View {
        ZStack {
            ringShape.modifier(TimedReveal(range: ring, style: .ring))
            checkShape.modifier(TimedReveal(range: check, style: .wipe))
        }
        .frame(width: IslandLayout.chosenBadge, height: IslandLayout.chosenBadge)
    }

    private var ringShape: some View {
        Circle()
            .inset(by: IslandLayout.chosenRingInset)
            .stroke(tint, lineWidth: IslandLayout.chosenRing)
    }

    private var checkShape: some View {
        CheckShape()
            .stroke(tint, style: StrokeStyle(lineWidth: IslandLayout.checkLine, lineCap: .round, lineJoin: .round))
            .frame(width: IslandLayout.check, height: IslandLayout.check)
    }
}

/// 按系统的时间露出来：`range` 这段时间里系统把进度条一帧一帧往前画，这里只拿它的透明度当遮罩，不用 App 更新。
/// 进度条的底（还没走到的地方）透过约四分之一，叠四层遮罩只剩约 0.4%，看不见
struct TimedReveal: ViewModifier {
    enum Style {
        /// 圆形：从 12 点顺时针
        case ring
        /// 横条：从左往右
        case wipe
    }

    let range: ClosedRange<Date>
    let style: Style

    func body(content: Content) -> some View {
        content
            .mask { TimedProgress(range: range, style: style) }
            .mask { TimedProgress(range: range, style: style) }
            .mask { TimedProgress(range: range, style: style) }
            .mask { TimedProgress(range: range, style: style) }
    }
}

/// 系统按时间画的进度条（白色）。圆形的填满给它的框；横条竖着拉高，盖住整个框，前沿就是一条竖线。
/// 固定从左到右：系统语言从右往左写时也是顺时针、从左往右
struct TimedProgress: View {
    let range: ClosedRange<Date>
    let style: TimedReveal.Style

    var body: some View {
        let bar = ProgressView(timerInterval: range, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .labelsHidden()
        .tint(.white)
        Group {
            switch style {
            case .ring:
                bar.progressViewStyle(.circular)
            case .wipe:
                bar.progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 40)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// 对勾：24 × 24 里从 (5, 12.5) 往右下到 (9.5, 17)，再往右上到 (19, 7.5)，和设计画布上的一样
struct CheckShape: Shape {
    private static let points = [CGPoint(x: 5, y: 12.5), CGPoint(x: 9.5, y: 17), CGPoint(x: 19, y: 7.5)]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
        return path
    }
}

/// 顶上一行右边的金额；选好以后留着
struct AmountText: View {
    let amount: String

    var body: some View {
        Text(amount)
            .font(IslandLayout.lineFont)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// 展开的岛下面那一块：还没选是按钮；选好的第一步是按钮那么高的空（按钮淡出），之后是选好的一行
struct IslandBottom: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        if let chosen = state.chosen {
            if state.step == .clearing {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: IslandLayout.grid, maxHeight: IslandLayout.grid)
            } else {
                ChosenRow(state: state, chosen: chosen)
                    .chosenReveal(state.step)
                    .dynamicTypeSize(...IslandLayout.largestType)
            }
        } else {
            PickerBody(state: state)
        }
    }
}

/// 按钮；锁屏上选好了显示选中的分类。不管几行都占两行的高度，内容上下居中（`IslandLayout.grid`）
struct PickerBody: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        Group {
            if let chosen = state.chosen {
                // 锁屏卡片：和岛上选好的一行一样（岛上用 `IslandBottom`）
                ChosenRow(state: state, chosen: chosen)
                    .chosenReveal(state.step)
            } else {
                CellGrid(recordID: state.recordID, cells: state.screen.cells, tint: state.tintColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandLayout.grid, maxHeight: IslandLayout.grid)
        .dynamicTypeSize(...IslandLayout.largestType)
    }
}

/// 一行 5 个（`LiveCategoryPicker.perRow`）；不满一行的靠左，整块居中；只有一行时在两行的高度里上下居中（`PickerBody`）
struct CellGrid: View {
    let recordID: String
    let cells: [LiveCategoryPicker.Cell]
    let tint: Color

    private var rows: [[LiveCategoryPicker.Cell]] {
        stride(from: 0, to: cells.count, by: LiveCategoryPicker.perRow).map {
            Array(cells[$0..<min($0 + LiveCategoryPicker.perRow, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.rowSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: IslandLayout.columnSpacing) {
                    ForEach(0..<rows[row].count, id: \.self) { index in
                        CellButton(recordID: recordID, cell: rows[row][index], tint: tint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 按钮 60 × 44：圆 28 里放图标，字（12 点）在圆下面。分类：主题色 22% 的圆、主题色图标；「全部」「更多」：白色 14% 的圆、白色图标
struct CellButton: View {
    let recordID: String
    let cell: LiveCategoryPicker.Cell
    let tint: Color

    var body: some View {
        switch cell.action {
        case .pick(let categoryID):
            Button(intent: PickLiveCategoryIntent(recordID: recordID, categoryID: categoryID)) { label }
                .buttonStyle(.plain)
        case .show(let page):
            Button(intent: ShowLiveCategoryPageIntent(recordID: recordID, page: page)) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
        VStack(spacing: 2) {
            Image(systemName: cell.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(cell.isNavigation ? Color.white : tint)
                .frame(width: IslandLayout.circle, height: IslandLayout.circle)
                .background(cell.isNavigation ? Color.white.opacity(0.14) : tint.opacity(0.22), in: Circle())
            Text(cell.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: IslandLayout.cell.width, height: IslandLayout.cell.height)
        .contentShape(Rectangle())
    }
}

/// 锁屏卡片：黑色 80%，和岛上一样的按钮。高 10 + 30 + 6 + 92 + 10 = 148，不超过上限
struct LockScreenCard: View {
    let state: CategoryActivityAttributes.ContentState

    var body: some View {
        if state.isReminderOnly, let notice = state.notice {
            ReminderCard(notice: notice, tint: state.tintColor)
        } else {
            pickerCard
        }
    }

    private var pickerCard: some View {
        VStack(spacing: 6) {
            HStack {
                HeaderLeading(state: state, inline: true)
                    .islandSwap(state.headerKey, back: state.isBack)
                Spacer(minLength: 8)
                AmountText(amount: state.amount)
                    .islandSwap(state.amountKey, back: state.isBack)
            }
            .frame(height: 30)
            PickerBody(state: state)
                .islandSwap(state.bottomKey, back: state.isBack)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dynamicTypeSize(...IslandLayout.largestType)
        .environment(\.colorScheme, .dark)
    }
}

/// 没有灵动岛的手机：锁屏卡片只放提醒，和岛上的提醒一样（左边收据图标，中间「刚刚记了一笔 / 待分类」，右边圆环里是待分类的笔数）。
/// 记上一笔时 App 发一次带提醒的更新，系统把这张卡片当横幅在屏幕上方弹一下。四边是苹果规范的 14 点
struct ReminderCard: View {
    let notice: CategoryActivityAttributes.Notice
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            NoticeIcon(tint: tint)
            BadgeText(caption: notice.caption, title: notice.title)
            NoticeCount(count: notice.count, tint: tint)
        }
        .padding(IslandLayout.lockMargin)
        .dynamicTypeSize(...IslandLayout.largestType)
        .environment(\.colorScheme, .dark)
    }
}
