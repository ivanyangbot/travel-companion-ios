import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Conversational AI itinerary planning (ChatGPT-style). The user chats with
/// the assistant; each assistant turn may propose a batch of itinerary cards
/// rendered inline as card components with per-card toggles. Selected cards
/// are imported via the existing draft-import queue.
struct AIItinerarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var syncEngine: SyncEngine

    @State private var turns: [ChatTurn] = []
    @State private var inputText: String = ""
    @State private var selectedCardIDs: Set<UUID> = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var images: [ImageAttachment] = []
    @State private var isSending = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var streamingTextBuffer = ""
    @State private var lastStreamRenderAt = ContinuousClock.now
    @FocusState private var inputFocused: Bool

    private static let maxImageCount = 4

    init(syncEngine: SyncEngine, initialSourceText: String? = nil) {
        self._syncEngine = ObservedObject(wrappedValue: syncEngine)
        _inputText = State(initialValue: initialSourceText ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                inputBar
            }
            .navigationTitle("AI 填入行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSending || isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !selectedCardIDs.isEmpty {
                        Button("导入选中 \(selectedCardIDs.count)") { importSelected() }
                            .disabled(isSending || isImporting)
                    }
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("正在加入同步队列…")
                        .padding(20)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty {
                        hint
                    }
                    ForEach(turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: turns.count) { _, _ in
                withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
            }
            .onChange(of: isSending) { _, _ in
                if isSending, let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: turns.last?.text) { _, _ in
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.indigo)
            Text("和 AI 一起规划行程")
                .font(.headline)
            Text("描述你想去的地方、想补充的日期，或上传攻略图片。AI 会在对话中生成卡片，勾选后一键导入。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        HStack {
            if turn.isUser { Spacer(minLength: 48) }
            VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 8) {
                if !turn.thinking.isEmpty {
                    // Streamed chain-of-thought in a distinct subtle block.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("思考过程", systemImage: "brain")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(turn.thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: 320, alignment: .leading)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if turn.text.isEmpty && !turn.isUser && turn.cards.isEmpty {
                    // Assistant is still generating: show a typing indicator in
                    // its own bubble until the first reply delta arrives.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(turn.status ?? "正在思考…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 320, alignment: .leading)
                } else {
                    if !turn.text.isEmpty || turn.isUser {
                        Text(turn.text)
                            .font(.body)
                            .padding(12)
                            .foregroundStyle(turn.isUser ? Color.white : Color.primary)
                            .background(turn.isUser ? Color.indigo : Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: 320, alignment: turn.isUser ? .trailing : .leading)
                    }
                    if !turn.cards.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(turn.cards) { card in
                                ItineraryChatCardView(
                                    card: card,
                                    isSelected: selectedCardIDs.contains(card.id),
                                    onToggle: {
                                        if selectedCardIDs.contains(card.id) {
                                            selectedCardIDs.remove(card.id)
                                        } else {
                                            selectedCardIDs.insert(card.id)
                                        }
                                }
                                )
                            }
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                    if let status = turn.status {
                        // Weak in-progress hint while the turn keeps streaming.
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(status).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.leading, 4)
                    }
                }
            }
            if !turn.isUser { Spacer(minLength: 48) }
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
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Button {
                                    images.removeAll { $0.id == image.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.5))
                                        .font(.title3)
                                }
                                .padding(2)
                            }
                        }
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: Self.maxImageCount, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                }
                .disabled(isSending)
                .onChange(of: photoItems) { _, _ in loadSelectedImages() }
                TextField("描述你想补充的行程…", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(isSending || !canSend)
            }
            .padding(10)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var canSend: Bool {
        !isSending && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private func loadSelectedImages() {
        Task {
            var loaded: [ImageAttachment] = []
            for item in photoItems.prefix(Self.maxImageCount) {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let attachment = ImageAttachment(data: data) {
                    loaded.append(attachment)
                }
            }
            await MainActor.run { self.images = loaded }
        }
    }

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let userText = text.isEmpty ? "请根据图片内容生成行程。" : text
        let imageDataURIs = images.map(\.dataURI)
        turns.append(ChatTurn(isUser: true, text: userText, cards: []))
        // Build history before seeding the empty assistant turn, and skip any
        // prior assistant turn that has no text (e.g. a stream that produced
        // nothing) so it cannot poison the server's messages validation.
        let history = turns.compactMap { turn -> AIItineraryChatRequest.Message? in
            if turn.isUser { return AIItineraryChatRequest.Message(role: "user", content: turn.text) }
            return turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : AIItineraryChatRequest.Message(role: "assistant", content: turn.text)
        }
        inputText = ""
        images = []
        photoItems = []
        isSending = true
        errorMessage = nil
        print("[AI UI] send_start userText=\(userText) historyCount=\(history.count) imageCount=\(imageDataURIs.count)")
        // Seed an empty assistant turn so reply deltas can stream into it live.
        let assistantIndex = turns.count
        turns.append(ChatTurn(isUser: false, text: "", cards: []))
        streamingTextBuffer = ""
        lastStreamRenderAt = .now
        var receivedAny = false
        do {
            let stream = try await syncEngine.streamItineraryChat(messages: history, preferences: nil, images: imageDataURIs.isEmpty ? nil : imageDataURIs)
            print("[AI UI] stream_created")
            for try await event in stream {
                receivedAny = true
                print("[AI UI] received_event=\(String(describing: event))")
                switch event {
                case .thinking(let chunk):
                    turns[assistantIndex].thinking += chunk
                    turns[assistantIndex].status = "正在思考…"
                case .reply(let chunk):
                    streamingTextBuffer += chunk
                    turns[assistantIndex].status = "正在回复…"
                    renderStreamingTextIfNeeded(at: assistantIndex)
                case .card(let index, let card):
                    flushStreamingText(at: assistantIndex)
                    insertStreamedCard(card, at: index, into: assistantIndex)
                    turns[assistantIndex].status = "正在生成第 \(index + 1) 张卡片…"
                case .cardUpdate(let index, let extras, let notes):
                    applyStreamedCardUpdate(extras: extras, notes: notes, at: index, into: assistantIndex)
                case .cardPlace(let index, let place, let verified):
                    applyStreamedCardPlace(place: place, verified: verified, at: index, into: assistantIndex)
                case .result(let result):
                    flushStreamingText(at: assistantIndex)
                    turns[assistantIndex].text = result.reply
                    turns[assistantIndex].status = nil
                    // Streamed cards were already server-verified before being
                    // emitted; only reconcile when the final batch differs so
                    // in-stream toggles are not lost to regenerated UUIDs.
                    if result.cards.count != turns[assistantIndex].cards.count {
                        turns[assistantIndex].cards = result.cards
                        for card in result.cards where card.isSelected { selectedCardIDs.insert(card.id) }
                    }
                }
            }
            flushStreamingText(at: assistantIndex)
            turns[assistantIndex].status = nil
        } catch {
            print("[AI UI] stream_error receivedAny=\(receivedAny) error=\(error)")
            // If nothing was streamed, fall back to the non-streaming endpoint
            // (known-good path) so a streaming glitch never leaves the user
            // staring at a stuck "thinking" bubble.
            if !receivedAny {
                turns.remove(at: assistantIndex)
                await sendFallback(history: history, images: imageDataURIs.isEmpty ? nil : imageDataURIs)
            } else {
                errorMessage = error.localizedDescription
            }
            isSending = false
            return
        }
        // Stream completed but produced no events (e.g. an empty body): drop
        // the placeholder and fall back rather than show a frozen indicator.
        if !receivedAny {
            print("[AI UI] stream_empty_falling_back")
            turns.remove(at: assistantIndex)
            await sendFallback(history: history, images: imageDataURIs.isEmpty ? nil : imageDataURIs)
        }
        isSending = false
        print("[AI UI] send_finished")
    }

    /// A streamed card renders immediately with its place marked as pending;
    /// the server's ``cardPlace`` event resolves selection state later.
    private func insertStreamedCard(_ card: AIItineraryDraft.Card, at index: Int, into turnIndex: Int) {
        print("[AI UI] insert_card index=\(index) title=\(card.title)")
        var pendingCard = card
        pendingCard.placePending = card.kind == .activity || card.kind == .hotel
        pendingCard.isSelected = false
        var cards = turns[turnIndex].cards
        if cards.indices.contains(index) {
            selectedCardIDs.remove(cards[index].id)
            cards[index] = pendingCard
        } else {
            cards.append(pendingCard)
        }
        turns[turnIndex].cards = cards
    }

    /// Apply the server-side Apple Maps verification outcome: a verified place
    /// auto-selects the card; a failed one stays unselected with its warning.
    private func applyStreamedCardPlace(place: AIChatPlace?, verified: Bool, at index: Int, into turnIndex: Int) {
        let placeName = place?.name ?? "<nil>"
        print("[AI UI] card_place index=\(index) verified=\(verified) place=\(placeName)")
        guard turns[turnIndex].cards.indices.contains(index) else {
            print("[AI UI] card_place_ignored_missing_card index=\(index)")
            return
        }
        var card = turns[turnIndex].cards[index]
        card.place = place
        card.placePending = false
        card.isSelected = verified
        turns[turnIndex].cards[index] = card
        if verified { selectedCardIDs.insert(card.id) } else { selectedCardIDs.remove(card.id) }
    }

    /// Merge streamed extended fields into an already-rendered card, keeping
    /// its identity so the user's toggle state survives the update.
    private func applyStreamedCardUpdate(extras: AICardExtras, notes: String?, at index: Int, into turnIndex: Int) {
        guard turns[turnIndex].cards.indices.contains(index) else { return }
        var card = turns[turnIndex].cards[index]
        var merged = card.extras ?? AICardExtras()
        merged.merge(extras)
        card.extras = merged.isEmpty ? nil : merged
        if let notes, !notes.isEmpty { card.notes = notes }
        turns[turnIndex].cards[index] = card
    }

    /// Coalesce tiny upstream deltas so the chat remains visibly incremental
    /// without forcing SwiftUI to lay out the whole conversation per character.
    private func renderStreamingTextIfNeeded(at assistantIndex: Int) {
        let elapsed = lastStreamRenderAt.duration(to: .now)
        guard streamingTextBuffer.count >= 12 || elapsed >= .milliseconds(80) else { return }
        turns[assistantIndex].text += streamingTextBuffer
        streamingTextBuffer = ""
        lastStreamRenderAt = .now
    }

    private func flushStreamingText(at assistantIndex: Int) {
        guard !streamingTextBuffer.isEmpty else { return }
        turns[assistantIndex].text += streamingTextBuffer
        streamingTextBuffer = ""
        lastStreamRenderAt = .now
    }

    /// Non-streaming fallback used when the SSE stream fails or yields nothing.
    /// Reuses the original (pre-stream) endpoint so the conversation still
    /// advances even if streaming is temporarily unavailable.
    private func sendFallback(history: [AIItineraryChatRequest.Message], images: [String]?) async {
        print("[AI UI] fallback_start historyCount=\(history.count) imageCount=\(images?.count ?? 0)")
        do {
            let result = try await syncEngine.sendItineraryChat(messages: history, preferences: nil, images: images)
            // Same contract as the streaming endpoint: coordinates originate
            // from the backend's destination-fenced Apple Maps verification.
            let cards = result.cards
            print("[AI UI] fallback_success reply=\(result.reply) cards=\(cards.count)")
            turns.append(ChatTurn(isUser: false, text: result.reply, cards: cards))
            for card in cards where card.isSelected { selectedCardIDs.insert(card.id) }
        } catch {
            print("[AI UI] fallback_error error=\(error)")
            errorMessage = error.localizedDescription
        }
    }

    private func importSelected() {
        let selected = turns.flatMap(\.cards).filter { selectedCardIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let grouped = Dictionary(grouping: selected, by: \.date)
        let draft = AIItineraryDraft(days: grouped.map { AIItineraryDraft.Day(date: $0.key, cards: $0.value) })
        isImporting = true
        errorMessage = nil
        Task {
            do {
                try await syncEngine.importAIDraft(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

private struct ChatTurn: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
    var cards: [AIItineraryDraft.Card]
    /// The model's streamed chain-of-thought, shown in a distinct subtle style.
    var thinking: String = ""
    /// Live status while this assistant turn is still streaming.
    var status: String? = nil
}

private struct ImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: UIImage
    let filename: String
    var kilobytes: Int { max(1, data.count / 1024) }
    var dataURI: String { "data:image/jpeg;base64,\(data.base64EncodedString())" }

    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        // Downscale the long edge to 1024 px and JPEG-compress to keep the request small.
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
        self.filename = "image.jpg"
    }
}
