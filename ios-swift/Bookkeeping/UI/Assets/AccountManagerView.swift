import SwiftUI
import BKModel

/// 管理银行卡：一个列表里切换每张卡启用 / 停用，按住一行上下拖动调整卡片的顺序（系统列表的拖动：
/// 按住的行浮在上层，其他行自动让开、补位），资产页的卡包跟着这个顺序。
///
/// 停用的卡不再参与自动记账和净资产，已有流水保留，在资产页最下方以灰色卡包显示。
/// 切换开关时行不移动。
struct AccountManagerView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 开关切换后到数据库写入完成之前，先显示新状态
    @State private var pending: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if store.allAccounts.isEmpty {
                    ContentUnavailableView("还没有银行卡", systemImage: "creditcard")
                } else {
                    List {
                        ForEach(store.allAccounts) { account in
                            Toggle(isOn: enabled(account)) { row(account) }
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
        }
    }

    private func enabled(_ account: Account) -> Binding<Bool> {
        Binding {
            pending[account.id] ?? !account.archived
        } set: { on in
            pending[account.id] = on
            Task {
                await store.setArchived(accountID: account.id, archived: !on)
                pending[account.id] = nil
            }
        }
    }

    private func row(_ account: Account) -> some View {
        let on = pending[account.id] ?? !account.archived
        return HStack(spacing: 12) {
            CardSwatch(account: account)
                .grayscale(on ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).lineLimit(1)
                Text(account.isCard ? "\(account.bankName) · \(account.cardType.displayName) · \(account.last4)" : account.cardType.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
