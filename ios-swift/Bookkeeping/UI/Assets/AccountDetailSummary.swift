import SwiftUI
import BKModel

/// 卡片详情里卡片下面、流水之前的部分：待处理提示；「交易记录」标题、币种（多币种的卡按币种分开看流水）和笔数。
/// 放在详情列表（`WalletDetailList`）里；卡片本身、流水、「暂无流水」和顶部按钮（含时间段）在别处。
/// 余额在卡片上，初始余额在「卡片信息」里。
///
/// 高度只随待处理提示变化：换币种、换时间段时这一格不变高变矮，下面的流水格子增减。
struct AccountDetailSummary: View {
    let model: WalletDetailModel
    let openPending: () -> Void
    let selectCurrency: (CurrencyCode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pendingCount > 0 {
                pendingStrip.padding(.bottom, 16)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("交易记录").font(.title3.weight(.semibold))
                if model.currencies.count > 1 {
                    currencyMenu
                }
                Spacer()
                Text("共 \(model.recordTotal) 笔").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    /// 只有这张卡有待处理的账单时出现。
    private var pendingStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
            Text("\(model.pendingCount) 条账单待处理").font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tapAction(openPending)
    }

    /// 每个币种的流水分开看，放在「交易记录」旁边。卡里没有的币种的交易按主币种扣款，放在主币种里
    private var currencyMenu: some View {
        let current = model.currency ?? model.currencies.first ?? .cny
        return Menu {
            ForEach(model.currencies, id: \.self) { code in
                Button { selectCurrency(code) } label: {
                    if code == current {
                        Label("\(code.chineseName) \(code.rawValue)", systemImage: "checkmark")
                    } else {
                        Text("\(code.chineseName) \(code.rawValue)")
                    }
                }
            }
        } label: {
            // 文字用 Color.primary：菜单里的层级样式 .primary 会跟着强调色变成蓝色
            HStack(spacing: 3) {
                Text(current.chineseName)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary)
        }
        .accessibilityLabel("币种：\(current.chineseName)")
    }
}

/// 当前币种、时间段里没有流水。单独一格，出现和消失不改变上面一格的高度
struct EmptyRecordsView: View {
    var body: some View {
        Text("暂无流水")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }
}

private extension View {
    /// 点按执行。不用 Button：按钮在手指横向划过后松手仍会触发，右滑返回时会同时点开它；点按手势一移动就不算
    func tapAction(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// 卡片详情里看哪段时间的流水（按收到通知的时间）。在详情右上角的时间段胶囊里选
enum RecordPeriod: Hashable {
    case all
    case thisWeek
    case thisMonth
    case lastMonth
    case thisYear
    /// 含开始和结束那天
    case custom(from: Date, to: Date)

    static let presets: [RecordPeriod] = [.all, .thisWeek, .thisMonth, .lastMonth, .thisYear]

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .thisWeek: "本周"
        case .thisMonth: "本月"
        case .lastMonth: "上月"
        case .thisYear: "今年"
        case .custom(let from, let to): "\(Fmt.shortDate(from))–\(Fmt.shortDate(to))"
        }
    }

    /// 查询的时间范围：含 `from`，不含 `to`
    func range(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        func interval(_ component: Calendar.Component, _ date: Date) -> (from: Date?, to: Date?) {
            guard let interval = calendar.dateInterval(of: component, for: date) else { return (nil, nil) }
            return (interval.start, interval.end)
        }
        switch self {
        case .all:
            return (nil, nil)
        case .thisWeek:
            return interval(.weekOfYear, now)
        case .thisMonth:
            return interval(.month, now)
        case .lastMonth:
            return interval(.month, calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        case .thisYear:
            return interval(.year, now)
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))
            return (start, end)
        }
    }

    /// 自定义时打开的初始日期：当前的自定义范围，否则本月 1 日到今天
    var customDates: (from: Date, to: Date) {
        if case .custom(let from, let to) = self { return (from, to) }
        let now = Date()
        let start = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        return (start, now)
    }
}

/// 自定义时间段：选开始和结束日期
struct CustomPeriodSheet: View {
    let initial: (from: Date, to: Date)
    let apply: (RecordPeriod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("结束", selection: $to, in: from..., displayedComponents: .date)
            }
            .navigationTitle("自定义时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") {
                        apply(.custom(from: from, to: to))
                        dismiss()
                    }
                }
            }
            .onAppear {
                from = initial.from
                to = initial.to
            }
        }
        .presentationDetents([.medium])
    }
}

struct PaletteGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            ForEach(CardPalette.all) { palette in
                Button { selection = palette.id } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.gradient)
                        .frame(height: 64)
                        .overlay(alignment: .bottomLeading) {
                            Text(palette.name).font(.footnote.weight(.semibold)).foregroundStyle(palette.textColor).padding(10)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.tint, lineWidth: selection == palette.id ? 3 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.name)
                .accessibilityAddTraits(selection == palette.id ? [.isSelected] : [])
            }
        }
    }
}
