import PhotosUI
import SwiftData
import SwiftUI

struct WalletEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var syncEngine: SyncEngine
    let item: LocalWalletItem?
    let existingSecret: WalletSecret?
    let onSaved: () -> Void

    @State private var label: String
    @State private var number: String
    @State private var note: String
    @State private var cardType: WalletCardType
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var showsPhotoPicker = false

    init(syncEngine: SyncEngine, item: LocalWalletItem? = nil, existingSecret: WalletSecret? = nil, onSaved: @escaping () -> Void = {}) {
        self.syncEngine = syncEngine
        self.item = item
        self.existingSecret = existingSecret
        self.onSaved = onSaved
        _label = State(initialValue: item?.label ?? "")
        _number = State(initialValue: existingSecret?.number ?? "")
        _note = State(initialValue: existingSecret?.note ?? "")
        _cardType = State(initialValue: existingSecret?.cardType.flatMap(WalletCardType.init(rawValue:)) ?? .other)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    artworkPreview
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    scanMenu
                }

                Section("卡片信息") {
                    TextField("标签，例如：护照号", text: $label)
                        .textInputAutocapitalization(.sentences)
                    TextField("号码", text: $number)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                    Picker("类型", selection: $cardType) {
                        ForEach(WalletCardType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                }

                Section {
                    Label("号码、备注和图形会在写入前加密，只保存在当前设备。", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("照片仅发送给你配置的 AI 服务做一次识别，不在本机或服务器留存。", systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(item == nil ? "添加卡片" : "编辑卡片")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave) }
            }
            .overlay {
                if isScanning {
                    ProgressView("正在识别…").padding(20).glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $showsCamera) {
                CameraPicker { image in scan(uiImage: image) }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: 1, matching: .images)
            .onChange(of: photoItems) { _, _ in loadPickedPhoto() }
        }
    }

    @ViewBuilder
    private var artworkPreview: some View {
        WalletCardArtwork(cardType: cardType, label: label.isEmpty ? "预览" : label, number: number.isEmpty ? "0000" : number)
            .scaleEffect(0.62)
            .frame(height: 124)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var scanMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("拍照", systemImage: "camera") { showsCamera = true }
            }
            Button("从相册选择", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
        } label: {
            Label("拍照录入", systemImage: "doc.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .disabled(isScanning || syncEngine.apiBaseURLText.isEmpty || !syncEngine.isUserAuthenticated)
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadPickedPhoto() {
        guard let item = photoItems.first else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                await MainActor.run { scan(uiImage: image) }
            }
            await MainActor.run { photoItems = [] }
        }
    }

    private func scan(uiImage: UIImage) {
        guard let prepared = Self.prepare(image: uiImage) else {
            errorMessage = "无法处理该照片，请换一张。"
            return
        }
        isScanning = true
        errorMessage = nil
        Task {
            do {
                let result = try await syncEngine.scanWalletCard(image: prepared.dataURI, styleHint: cardType.styleHint)
                await MainActor.run {
                    if !result.label.isEmpty { label = result.label }
                    number = result.number.isEmpty ? number : result.number
                    if let note = result.note, !note.isEmpty { self.note = note }
                    if let detected = result.cardType { cardType = detected }
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    isScanning = false
                    errorMessage = "识别失败：\(error.localizedDescription)。可手动填写后保存。"
                }
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            errorMessage = "请填写标签。"
            return
        }
        guard !trimmedNumber.isEmpty else {
            errorMessage = "请填写要保存的号码。"
            return
        }

        let image = WalletCardArtworkRenderer.pngData(type: cardType, label: trimmedLabel, number: trimmedNumber)
        do {
            let secret = WalletSecret(
                number: trimmedNumber,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                cardType: cardType.rawValue,
                image: image
            )
            let encryptedSecret = try WalletCrypto.encrypt(secret, using: KeychainStore().walletKey())
            if let item {
                item.label = trimmedLabel
                item.encryptedSecret = encryptedSecret
                item.updatedAt = .now
            } else {
                modelContext.insert(LocalWalletItem(label: trimmedLabel, encryptedSecret: encryptedSecret))
            }
            try modelContext.save()
            onSaved()
            dismiss()
        } catch {
            errorMessage = "本机加密存储失败：\(error.localizedDescription)"
        }
    }

    /// 缩放长边到 1024 px、JPEG 0.6 压缩，保持请求体小巧。
    private static func prepare(image: UIImage) -> (data: Data, dataURI: String)? {
        let maxEdge: CGFloat = 1024
        let size = image.size
        let scale = min(maxEdge / max(size.width, size.height), 1)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.6) else { return nil }
        let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        return (jpeg, dataURI)
    }
}
