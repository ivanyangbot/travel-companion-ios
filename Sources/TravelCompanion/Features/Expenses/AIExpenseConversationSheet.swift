import SwiftUI
import PhotosUI

/// 扫小票/对话生成一笔实际价支出（接入大模型）。复用卡片对话的交互范式：
/// 附加小票照片 + 多轮对话，服务端返回支出草案（金额/类别/日期/备注），
/// 缺字段时禁用确认；确认页可选关联某张卡片后保存为实际价支出。
struct AIExpenseConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var syncEngine: SyncEngine
    let trip: SharedTripSnapshot
    let onConfirm: (ExpenseRequest) -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var images: [ImageAttachment] = []
    @State private var draft: AIExpenseDraftCard?
    @State private var missingRequired: [String] = []
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showsPreview = false

    private static let maxImages = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chatList
                inputBar
            }
            .navigationTitle("expenseAI.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(isGenerating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("walleteditor.previewLabel") { showsPreview = true }
                        .disabled(draft == nil || !missingRequired.isEmpty)
                }
            }
            .sheet(isPresented: $showsPreview) {
                if let draft {
                    ExpenseDraftPreviewSheet(
                        draft: draft,
                        trip: trip,
                        missingRequired: missingRequired,
                        onConfirm: { request in
                            showsPreview = false
                            onConfirm(request)
                            dismiss()
                        },
                        onModify: { showsPreview = false },
                        onCancel: { showsPreview = false }
                    )
                }
            }
            .overlay { if isGenerating { generatingOverlay } }
        }
    }

    private var chatList: some View {
        ScrollView {
            if messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 40)).foregroundStyle(.tint)
                    Text("expenseAI.hint")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in ChatBubble(message: message) }
                }
                .padding(16)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image.thumbnail)
                                    .resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Button {
                                    images.removeAll { $0.id == image.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6)).padding(2)
                                }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: Self.maxImages, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title2).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(images.count >= Self.maxImages)
                .accessibilityLabel(Text("expenseAI.addPhotoA11y"))
                .onChange(of: photoItems) { _, _ in loadSelectedImages() }
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("expenseAI.placeholder").foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.vertical, 10)
                    }
                    TextEditor(text: $inputText)
                        .frame(minHeight: 40, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                }
                .padding(4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button { send() } label: {
                    Image(systemName: "paperplane.fill").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!canSend)
                .accessibilityLabel(Text("expenseAI.sendA11y"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 16)
            }
        }
        .background(.bar)
    }

    private var generatingOverlay: some View {
        ProgressView("expenseAI.generating")
            .padding(20)
            .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var canSend: Bool {
        !isGenerating && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: trimmed.isEmpty ? String(localized: "expenseAI.receiptAttached") : trimmed))
        let imageDataURIs = images.map(\.dataURI)
        let history = messages.map { AIExpenseConversationRequest.Message(role: $0.role.rawValue, content: $0.text) }
        inputText = ""
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let result = try await syncEngine.createAIExpenseDraft(dayDate: todayOrNearestDate(), messages: history, images: imageDataURIs)
                messages.append(ChatMessage(role: .assistant, text: result.reply))
                draft = result.expenseDraft
                missingRequired = result.missingRequired ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func todayOrNearestDate() -> String {
        let sorted = trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
        let today = Self.dayFormatter.string(from: .now)
        if sorted.contains(where: { $0.date == today }) { return today }
        return sorted.first?.date ?? today
    }

    private func loadSelectedImages() {
        Task {
            var loaded: [ImageAttachment] = []
            for item in photoItems.prefix(Self.maxImages - images.count) {
                if let data = try? await item.loadTransferable(type: Data.self), let attachment = ImageAttachment(data: data) {
                    loaded.append(attachment)
                }
            }
            await MainActor.run {
                self.images.append(contentsOf: loaded)
                self.photoItems = []
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    enum Role: String { case user, assistant }
}

private struct ChatBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

/// 预览支出草案，可选关联卡片后确认保存为实际价支出。
struct ExpenseDraftPreviewSheet: View {
    let draft: AIExpenseDraftCard
    let trip: SharedTripSnapshot
    let missingRequired: [String]
    let onConfirm: (ExpenseRequest) -> Void
    let onModify: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardID: Int? = nil

    private var currency: String { draft.currency ?? trip.currency ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section("expenseeditor.actualSection") {
                    LabeledContent("expenseAI.amount") {
                        Text(formattedAmount).font(.headline.monospacedDigit())
                    }
                    if let category = draft.category {
                        LabeledContent("expenseAI.category") { Label(category.title, systemImage: category.systemImage) }
                    }
                    if let occurredOn = draft.occurredOn {
                        LabeledContent("expenseAI.date", value: occurredOn)
                    }
                }
                Section("expenseeditor.linkSection") {
                    Picker("expenseeditor.cardLabel", selection: $cardID) {
                        Text("expenseeditor.noCard").tag(Int?.none)
                        ForEach(allCards, id: \.serverID) { card in
                            Text(card.title).tag(Optional(card.serverID!))
                        }
                    }
                }
                if let note = draft.note, !note.isEmpty {
                    Section("cardeditor.notesSection") { Text(note) }
                }
                if !missingRequired.isEmpty {
                    Section {
                        Label(String(localized: "expenseAI.needMore") + missingRequired.map(Self.fieldLabel).joined(separator: "、"), systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("expenseAI.previewTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { onCancel() } }
                ToolbarItem(placement: .primaryAction) { Button("expenseAI.edit") { onModify() }.foregroundStyle(.secondary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("expenseAI.confirmAdd") { onConfirm(buildRequest()) }.disabled(!missingRequired.isEmpty)
                }
            }
        }
    }

    private var allCards: [TravelCardSnapshot] {
        trip.days.flatMap(\.cards).filter { $0.serverID != nil }.sorted { $0.title < $1.title }
    }

    private var formattedAmount: String {
        guard let minor = draft.amountMinor, let currency = draft.currency else { return draft.amountMinor.map { "\($0)" } ?? "—" }
        return ExpenseMoney.formatted(minor, currency: currency)
    }

    private func buildRequest() -> ExpenseRequest {
        ExpenseRequest(
            amountMinor: draft.amountMinor,
            currency: draft.currency,
            category: draft.category,
            occurredOn: draft.occurredOn,
            note: draft.note,
            cardID: cardID,
            fieldsToClear: []
        )
    }

    static func fieldLabel(_ name: String) -> String {
        switch name {
        case "amountMinor": String(localized: "expenseAI.amount")
        case "category": String(localized: "expenseAI.category")
        case "occurredOn": String(localized: "expenseAI.date")
        default: name
        }
    }
}

private struct ImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: UIImage
    var dataURI: String { "data:image/jpeg;base64,\(data.base64EncodedString())" }

    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        let maxEdge: CGFloat = 1024
        let size = image.size
        let scale = min(maxEdge / max(size.width, size.height), 1)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.6) else { return nil }
        self.data = jpeg
        self.thumbnail = resized
    }
}
