import SwiftUI
import BKModel

/// 管理银行卡：停用、删除都在这一页。左滑一行露出两个按钮：最右边红色「删除」，旁边灰色「停用」
/// （停用的卡是主题色的「启用」）。不能一划到底直接删，免得误删。
/// 删除先弹一次确认；流水留着，账户名称后面写「已删除」，不能恢复。使用中的卡也能直接删，不用先停用。
/// 按住一行上下拖动调整卡片的顺序（系统列表的拖动：按住的行浮在上层，其他行自动让开、补位），资产页的卡包跟着这个顺序。
///
/// 停用的卡不再参与自动记账和净资产，已有流水保留，在资产页最下方以灰色卡包显示；这里的行变灰、写「已停用」。
struct AccountManagerView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 点了停用 / 启用、数据库写入完成之前，先显示新状态
    @State private var pending: [String: Bool] = [:]
    /// 等确认删除的账户
    @State private var deleting: Account?
    /// 「启用」用主题色（`Color.accentColor` 是固定的蓝色）
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue

    var body: some View {
        NavigationStack {
            Group {
                if store.allAccounts.isEmpty {
                    ContentUnavailableView("还没有银行卡", systemImage: "creditcard")
                } else {
                    List {
                        ForEach(store.allAccounts) { account in
                            let enabled = pending[account.id] ?? !account.archived
                            AccountSummaryRow(account: account, enabled: enabled)
                                // 第一个按钮在最右边
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    // 不用 .destructive：那样一点就先把这一行划走，确认前就不见了
                                    Button("删除", systemImage: "trash") { deleting = account }
                                        .tint(.red)
                                    if enabled {
                                        Button("停用", systemImage: "pause.circle") { setEnabled(account, false) }
                                            .tint(.gray)
                                    } else {
                                        Button("启用", systemImage: "play.circle") { setEnabled(account, true) }
                                            .tint(ThemeColor.color(stored: themeColor))
                                    }
                                }
                        }
                        .onMove { from, to in
                            var ids = store.allAccounts.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            store.reorderAccounts(ids)
                        }
                    }
                }
            }
            .navigationTitle("管理银行卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { dismiss() } }
            }
            .confirmationDialog(
                Text(L("删除「\(deleting?.localizedName ?? "")」？")),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { account in
                Button("删除", role: .destructive) { delete(account) }
            } message: { _ in
                Text("流水会保留，账户名称后面写「已删除」。删除后不能恢复。")
            }
        }
    }

    private func setEnabled(_ account: Account, _ on: Bool) {
        pending[account.id] = on
        Task {
            await store.setArchived(accountID: account.id, archived: !on)
            pending[account.id] = nil
        }
    }

    private func delete(_ account: Account) {
        Task {
            guard (try? await store.deleteAccount(id: account.id)) != nil else { return }
            if let image = account.face.imageID { CardFaceImages.shared.discard([image]) }
        }
    }
}

/// 一行账户：小卡面、名称，下面银行 · 卡类型 · 尾号。管理银行卡和新手引导共用
struct AccountSummaryRow: View {
    let account: Account
    var enabled = true

    var body: some View {
        HStack(spacing: 12) {
            CardSwatch(account: account)
                .grayscale(enabled ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.localizedName).lineLimit(1)
                Text(account.isCard ? "\(account.localizedBankName) · \(account.cardType.displayName.loc) · \(account.last4)" : account.cardType.displayName.loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(enabled ? 1 : 0.5)
            if !enabled {
                Spacer(minLength: 8)
                Text("已停用").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// 列表里的小卡面：自定义图片（已解码时）或配色渐变。
private struct CardSwatch: View {
    let account: Account

    private static let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    var body: some View {
        Group {
            if let id = account.face.imageID, let image = CardFaceImages.shared.image(id) {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                CardPalette.named(account.paletteID).gradient
            }
        }
        .frame(width: 46, height: 46 / AppLayout.cardAspect)
        .clipShape(Self.shape)
        .accessibilityHidden(true)
    }
}
