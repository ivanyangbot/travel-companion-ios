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

                Section("walleteditor.infoSection") {
                    TextField("walleteditor.labelPlaceholder", text: $label)
                        .textInputAutocapitalization(.sentences)
                    TextField("walleteditor.numberPlaceholder", text: $number)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("walleteditor.notePlaceholder", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                    Picker("walleteditor.typeLabel", selection: $cardType) {
                        ForEach(WalletCardType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                }

                Section {
                    Label("walleteditor.encryptNote", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("walleteditor.photoNote", systemImage: "eye.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(item == nil ? "walleteditor.addTitle" : "walleteditor.editTitle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("common.save", action: save).disabled(!canSave) }
            }
            .overlay {
                if isScanning {
                    ProgressView("walleteditor.recognizing").padding(20).glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .alert("walleteditor.cannotSave", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("common.ok", role: .cancel) { errorMessage = nil }
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
        WalletCardArtwork(cardType: cardType, label: label.isEmpty ? String(localized: "walleteditor.previewLabel") : label, number: number.isEmpty ? String(localized: "walleteditor.previewNumber") : number)
            .scaleEffect(0.62)
            .frame(height: 124)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var scanMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("walleteditor.takePhoto", systemImage: "camera") { showsCamera = true }
            }
            Button("walleteditor.fromLibrary", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
        } label: {
            Label("walleteditor.photoMenu", systemImage: "doc.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .disabled(isScanning || syncEngine.apiBaseURLText.isEmpty)
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
            errorMessage = String(localized: "walleteditor.photoError")
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
                    errorMessage = String(format: String(localized: "walleteditor.recognizeFailed"), error.localizedDescription)
                }
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            errorMessage = String(localized: "walleteditor.errorLabel")
            return
        }
        guard !trimmedNumber.isEmpty else {
            errorMessage = String(localized: "walleteditor.errorNumber")
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
            errorMessage = String(format: String(localized: "walleteditor.encryptFailed"), error.localizedDescription)
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
