import SwiftUI
import PhotosUI
import BKModel

/// 编辑卡面：配色或相册图片作背景，文字颜色和大小。只影响显示，不影响账户匹配。
/// 卡片固定在最上面，往下调文字时也一直看得到。用图片时卡片上只有金额，可以改描边颜色，在卡片上拖动调位置。
/// 选图后立即裁剪缩小存成文件；没有保存就关闭时删除这次新存的图片。
struct CardFaceEditor: View {
    let accountID: String
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var paletteID = ""
    @State private var face = CardFace.standard
    @State private var loaded = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var importing = false
    @State private var saving = false
    @State private var saved = false
    @State private var importedIDs: [String] = []
    @State private var errorText: String?
    /// 预览卡片的像素宽度：选图时缩小到这个尺寸
    @State private var pixelWidth: CGFloat = 1080
    @State private var cardSize = CGSize.zero
    @State private var amountSize = CGSize.zero
    /// 这次拖动开始时金额的位置
    @State private var dragStart: CGPoint?

    var body: some View {
        NavigationStack {
            if let account = store.account(id: accountID) {
                form(account)
            }
        }
        .onDisappear {
            // 没有保存：删除这次选过的图片
            if !saved { CardFaceImages.shared.discard(importedIDs) }
        }
    }

    private func form(_ account: Account) -> some View {
        var preview = account
        preview.paletteID = paletteID
        preview.face = face
        let palette = CardPalette.named(paletteID)
        let photo = face.imageID != nil
        return Form {
            Section {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    HStack {
                        Label(face.imageID == nil ? "从相册选择图片" : "更换图片", systemImage: "photo")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
                if photo {
                    Button("移除图片", systemImage: "trash", role: .destructive) { face.imageID = nil }
                }
            } header: {
                Text("背景图片")
            }

            if !photo {
                Section("配色") {
                    PaletteGrid(selection: $paletteID).padding(.vertical, 4)
                }
            }

            Section(photo ? "金额" : "文字") {
                colorRows(photo ? "金额颜色" : "文字颜色", selection: $face.textColor, default: photo ? WalletCardView.photoTextColor : palette.text)
                if photo {
                    colorRows("描边颜色", selection: $face.outlineColor, default: WalletCardView.photoOutlineColor)
                }
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(photo ? "金额大小" : "文字大小", value: "\(Int((face.textScale * 100).rounded()))%")
                    Slider(value: $face.textScale, in: CardFace.textScaleRange, step: 0.05) {
                        Text(photo ? "金额大小" : "文字大小")
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                .padding(.vertical, 2)
            }

            if photo {
                // 大范围在卡片上拖，微调用滑杆
                Section("拖动卡片调整金额位置") {
                    Slider(value: $face.amountX, in: CardFace.amountPositionRange) {
                        Text("左右位置")
                    } minimumValueLabel: {
                        Text("左")
                    } maximumValueLabel: {
                        Text("右")
                    }
                    Slider(value: $face.amountY, in: CardFace.amountPositionRange) {
                        Text("上下位置")
                    } minimumValueLabel: {
                        Text("上")
                    } maximumValueLabel: {
                        Text("下")
                    }
                    if face.amountX != CardFace.standard.amountX || face.amountY != CardFace.standard.amountY {
                        Button("恢复默认位置") {
                            face.amountX = CardFace.standard.amountX
                            face.amountY = CardFace.standard.amountY
                        }
                    }
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .safeAreaBar(edge: .top) {
            Color.clear
                .aspectRatio(AppLayout.cardAspect, contentMode: .fit)
                .overlay {
                    WalletCardView(
                        account: preview,
                        balanceText: store.balances[account.id]?.cardText ?? L("余额未知"),
                        amountSize: $amountSize
                    )
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    cardSize = $0
                    pixelWidth = min(1200, $0.width * displayScale)
                }
                .contentShape(Rectangle())
                .gesture(amountDrag, isEnabled: photo)
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.bottom, 8)
        }
        // 拖金额时不要把弹窗一起拉下来
        .interactiveDismissDisabled(dragStart != nil)
        .navigationTitle("编辑卡面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark") { Task { await save(account) } }
                    .disabled(saving || importing)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            paletteID = account.paletteID
            face = account.face
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await importImage(item) }
        }
    }

    /// 常用的文字颜色：系统色盘是弹窗，可能盖住卡片；点这里不用打开它，卡片上马上变
    private static let textColors: [(name: String, hex: UInt32)] = [
        ("白色", 0xFFFFFF), ("黑色", 0x000000), ("金色", 0xF5D76E), ("红色", 0xFF453A), ("绿色", 0x30D158), ("蓝色", 0x64D2FF),
    ]

    /// 手指在卡片哪里都能拖，金额跟着手指走同样的距离（手指不会挡住金额）
    private var amountDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? CGPoint(x: face.amountX, y: face.amountY)
                dragStart = start
                let travel = WalletCardView.amountTravel(card: cardSize, amount: amountSize)
                face.amountX = CardFace.clampedAmountPosition(start.x + value.translation.width / travel.width)
                face.amountY = CardFace.clampedAmountPosition(start.y + value.translation.height / travel.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    @ViewBuilder
    private func colorRows(_ title: String, selection: Binding<UInt32?>, default defaultColor: UInt32) -> some View {
        ColorPicker(title.loc, selection: color(selection, default: defaultColor), supportsOpacity: false)
        colorSwatches(selection, default: defaultColor)
        if selection.wrappedValue != nil {
            Button(L("恢复默认\(title.loc)")) { selection.wrappedValue = nil }
        }
    }

    private func colorSwatches(_ selection: Binding<UInt32?>, default defaultColor: UInt32) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.textColors, id: \.hex) { color in
                let isSelected = (selection.wrappedValue ?? defaultColor) == color.hex
                Button {
                    selection.wrappedValue = color.hex
                } label: {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.separator))
                        .padding(3)
                        .overlay(Circle().stroke(.tint, lineWidth: isSelected ? 2 : 0))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name.loc)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private func color(_ selection: Binding<UInt32?>, default defaultColor: UInt32) -> Binding<Color> {
        Binding {
            Color(hex: selection.wrappedValue ?? defaultColor)
        } set: { color in
            selection.wrappedValue = color.hex
        }
    }

    private func importImage(_ item: PhotosPickerItem) async {
        importing = true
        defer {
            importing = false
            pickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CardFaceImages.ImportError.unreadable }
            // 缩小到卡片在屏幕上的像素宽度；低端机屏幕小，图片也小
            let pixelWidth = pixelWidth
            let id = try await Task.detached(priority: .userInitiated) {
                try CardFaceImages.importImage(data, pixelWidth: pixelWidth, aspect: AppLayout.cardAspect)
            }.value
            importedIDs.append(id)
            face.imageID = id
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? L("无法读取这张图片")
        }
    }

    private func save(_ account: Account) async {
        saving = true
        defer { saving = false }
        do {
            try await store.updateCardFace(accountID: account.id, paletteID: paletteID, face: face)
            saved = true
            // 删除被替换的旧图和这次选过但没用上的图
            var unused = importedIDs.filter { $0 != face.imageID }
            if let old = account.face.imageID, old != face.imageID { unused.append(old) }
            CardFaceImages.shared.discard(unused)
            dismiss()
        } catch {
            errorText = L("保存失败：\(error.localizedDescription)")
        }
    }
}
