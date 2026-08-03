import PhotosUI
import SwiftUI

/// The PRD's local-first planning workbench. Drafts remain local until the
/// user explicitly selects and commits candidate cards.
struct AgentWorkbenchView: View {
    @ObservedObject var syncEngine: SyncEngine
    @StateObject private var store = AgentV2SessionStore()
    @FocusState private var isComposerFocused: Bool
    @State private var message = ""
    @State private var status: String?
    @State private var reasoningSummary = ""
    @State private var streamingReply = ""
    @State private var liveCards: [AgentV2LiveCard] = []
    @State private var stagedSummaryText = ""
    @State private var error: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var photo: PhotosPickerItem?
    @State private var isCommitting = false
    @State private var isShowingContext = false
    @State private var isConfirmingClear = false
    private let client = APIClient()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if store.session.messages.isEmpty && store.session.draft == nil {
                            welcomeView
                        } else {
                            conversationView
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
                .onChange(of: store.session.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: streamingReply) { _, _ in scrollToBottom(proxy, animated: false) }
                .onChange(of: liveCards.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.session.draft?.candidates.count ?? 0) { _, _ in scrollToBottom(proxy) }
            }
            .navigationTitle("旅行 Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(isPresented: $isShowingContext) {
                AgentContextSheet(syncEngine: syncEngine, store: store)
            }
            .confirmationDialog("清除本机 Agent 草稿？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                Button("清除对话与草稿", role: .destructive) { clearSession() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已加入行程的内容不会受到影响。")
            }
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .onDisappear { generationTask?.cancel() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { isShowingContext = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                    Text(tripTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("旅行与偏好设置")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { isShowingContext = true } label: {
                    Label("旅行与偏好", systemImage: "slider.horizontal.3")
                }
                Divider()
                Button(role: .destructive) { isConfirmingClear = true } label: {
                    Label("清除对话与草稿", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多操作")
        }
    }

    private var tripTitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "未设置旅行" }
        return trip.destination ?? "本次旅行"
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle().fill(Color.indigo.gradient).frame(width: 52, height: 52)
                    Image(systemName: "sparkles").font(.title2.weight(.semibold)).foregroundStyle(.white)
                }
                Text("一起把旅程安排好")
                    .font(.title2.weight(.bold))
                Text("说说你想去哪里、同行人和时间范围。我会先给出可检查的建议，只有你确认后才会加入行程。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            tripContextCard

            VStack(alignment: .leading, spacing: 12) {
                Text("可以这样问")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(quickPrompts, id: \.self) { prompt in
                    Button { usePrompt(prompt) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: promptIcon(prompt))
                                .frame(width: 24)
                                .foregroundStyle(.indigo)
                            Text(prompt)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(15)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tripContextCard: some View {
        Button { isShowingContext = true } label: {
            HStack(spacing: 12) {
                Image(systemName: syncEngine.trip?.isConfigured == true ? "map.fill" : "calendar.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 36, height: 36)
                    .background(Color.indigo.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(tripTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(tripContextSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var tripContextSubtitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "先设置目的地、日期和币种，再开始规划" }
        var details = ["\(trip.startDate ?? "") – \(trip.endDate ?? "")"]
        let preferences = preferenceLabels
        if !preferences.isEmpty { details.append(preferences.joined(separator: " · ")) }
        return details.joined(separator: "  ·  ")
    }

    private var preferenceLabels: [String] {
        let preferences = store.session.preferences
        return [
            preferenceTitle(preferences.pace, values: ["relaxed": "轻松", "balanced": "均衡", "packed": "特种兵"]),
            preferenceTitle(preferences.companions, values: ["solo": "独自", "couple": "情侣", "parents": "带父母", "children": "带儿童"]),
            preferenceTitle(preferences.budget, values: ["value": "省钱", "balanced": "适中", "premium": "品质优先"])
        ].compactMap { $0 }
    }

    private func preferenceTitle(_ value: String?, values: [String: String]) -> String? {
        guard let value else { return nil }
        return values[value]
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(store.session.messages) { item in
                ChatMessageView(message: item)
            }

            if !streamingReply.isEmpty {
                AssistantMessageContainer {
                    Text(streamingReply)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let status {
                AssistantMessageContainer {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                    }
                }
            }

            if !reasoningSummary.isEmpty {
                AssistantMessageContainer {
                    DisclosureGroup("查看思考摘要") {
                        Text(reasoningSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .font(.footnote.weight(.medium))
                    .tint(.secondary)
                }
            }

            if !liveCards.isEmpty {
                AssistantMessageContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正在生成候选")
                            .font(.subheadline.weight(.semibold))
                        ForEach(liveCards) { card in
                            LiveCandidateCard(card: card)
                        }
                    }
                }
            }

            if store.session.summary != nil || store.session.draft != nil {
                AssistantMessageContainer {
                    workbenchView
                }
            }
        }
    }

    @ViewBuilder private var workbenchView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = store.session.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本轮建议", systemImage: "sparkles")
                        .font(.headline)
                    Text(summary.text)
                    if !summary.pending.isEmpty {
                        Label(summary.pending.joined(separator: "、"), systemImage: "questionmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let draft = store.session.draft {
                let visible = Array(draft.candidates.prefix(6))
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("候选行程").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(visible) { candidate in
                            AgentV2CandidateCard(candidate: candidate) { value in
                                store.setSelected(value, id: candidate.id)
                            }
                        }
                        if draft.candidates.count > 6 {
                            Text("其余 \(draft.candidates.count - 6) 项已收起，请缩小本轮范围后继续调整。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !draft.changes.isEmpty {
                    DisclosureGroup("查看变更清单（\(draft.changes.count)）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.changes) { change in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: change.operation.symbol)
                                        .foregroundStyle(change.operation.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(change.operationTitle + " · " + change.summary)
                                            .font(.subheadline)
                                        if let impact = change.impact {
                                            Text(impact).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.secondary)
                }

                let selected = draft.candidates.filter(\.selected)
                VStack(alignment: .leading, spacing: 8) {
                    Button { commit() } label: {
                        HStack {
                            if isCommitting { ProgressView().tint(.white) }
                            Text("确认加入行程（\(selected.count)）")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(selected.isEmpty || selected.contains(where: { !$0.isCommitReady }) || isCommitting)
                    .opacity(selected.isEmpty || selected.contains(where: { !$0.isCommitReady }) ? 0.45 : 1)

                    if selected.contains(where: { !$0.isCommitReady }) {
                        Text("活动和酒店必须显示“地点已验证”；航班需完整航班与机场信息。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("确认前不会改动当前行程，未选择的候选仍留在本机草稿中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !store.session.attachments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("已附 \(store.session.attachments.count) 张图片")
                    Text("· 发送失败后仍可重试").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .onChange(of: photo) { _, item in load(item) }
                .accessibilityLabel("添加攻略图片")

                TextField("告诉 Agent 你的想法", text: $message, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .onSubmit { if canSend { send() } }

                Button { generationTask == nil ? send() : cancelGeneration() } label: {
                    Image(systemName: generationTask == nil ? "arrow.up" : "stop.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend || generationTask != nil ? .white : .secondary)
                        .frame(width: 36, height: 36)
                        .background(canSend || generationTask != nil ? Color.indigo : Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(generationTask == nil && !canSend)
                .accessibilityLabel(generationTask == nil ? "发送" : "停止生成")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && generationTask == nil
    }

    private var quickPrompts: [String] {
        [
            "帮我安排明天，带父母、少走路。",
            "第二天下午换成室内活动。",
            "按人均 500 元补齐空白日。",
            "根据这几张攻略图整理必去点。"
        ]
    }

    private func promptIcon(_ prompt: String) -> String {
        if prompt.contains("父母") { return "figure.2.and.child.holdinghands" }
        if prompt.contains("室内") { return "cloud.rain" }
        if prompt.contains("500") { return "banknote" }
        return "photo.stack"
    }

    private func usePrompt(_ prompt: String) {
        message = prompt
        isComposerFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func clearSession() {
        generationTask?.cancel()
        store.discardTurn()
        status = nil
        streamingReply = ""
        reasoningSummary = ""
        stagedSummaryText = ""
        liveCards = []
        store.clear()
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        store.discardTurn()
        status = nil
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { error = "无法读取图片。"; return }
            guard data.count <= 2_000_000 else { error = "请使用不超过 2 MB 的攻略图片，以保留可重试的本机副本。"; return }
            store.addAttachment(.init(id: UUID(), mediaType: "image/jpeg", dataURI: "data:image/jpeg;base64," + data.base64EncodedString()))
            photo = nil
        }
    }

    private func send() {
        guard let request = makeRequest() else { error = "请先完成旅行设置。"; return }
        let userMessage = AgentV2TurnRequest.Message(id: UUID(), role: "user", content: message, createdAt: .now)
        store.beginTurn()
        store.append(userMessage)
        message = ""
        streamingReply = ""
        reasoningSummary = ""
        stagedSummaryText = ""
        liveCards = []
        status = "正在理解你的需求…"
        isComposerFocused = false
        generationTask = Task {
            do {
                let stream = try await client.agentV2Stream(request)
                for try await event in stream {
                    switch event {
                    case .status(let text): status = text
                    case .reasoningSummary(let text): reasoningSummary += text
                    case .assistantDelta(let text):
                        status = nil
                        streamingReply += text
                    case .cardBegin(let id, let index):
                        if !liveCards.contains(where: { $0.id == id }) { liveCards.append(.init(id: id, index: index)) }
                    case .cardFieldDelta(let id, let field, let value):
                        guard let index = liveCards.firstIndex(where: { $0.id == id }) else { break }
                        liveCards[index].fields[field] = value
                    case .question(let text): store.append(.init(id: UUID(), role: "assistant", content: text, createdAt: .now))
                    case .summary(let summary):
                        stagedSummaryText = summary.text
                        store.apply(event)
                    case .candidateUpsert:
                        store.apply(event)
                    case .done:
                        let completedReply = streamingReply.isEmpty ? stagedSummaryText : streamingReply
                        if !completedReply.isEmpty {
                            store.append(.init(id: UUID(), role: "assistant", content: completedReply, createdAt: .now))
                            streamingReply = ""
                        }
                        store.completeTurn()
                        liveCards = []
                    default: store.apply(event)
                    }
                }
            } catch is CancellationError {
                // The persisted draft, input context and attachments remain retryable.
            } catch { self.error = error.localizedDescription }
            self.store.discardTurn()
            self.liveCards = []
            self.stagedSummaryText = ""
            self.status = nil
            self.generationTask = nil
        }
    }

    private func makeRequest() -> AgentV2TurnRequest? {
        guard let trip = syncEngine.trip, trip.isConfigured else { return nil }
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(id: card.serverID, kind: card.kind.rawValue, title: card.title, startAt: ISO8601DateFormatter().string(from: card.startAt), endAt: card.endAt.map { ISO8601DateFormatter().string(from: $0) }, place: card.place?.name, notes: card.notes)
            })
        }
        return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "itinerary", message: message, trip: .init(destination: trip.destination, startDate: trip.startDate, endDate: trip.endDate, currency: trip.currency, timeZone: TimeZone.current.identifier, version: trip.version, days: days), preferences: store.session.preferences, history: store.session.messages, activeDraft: store.session.draft, attachments: store.session.attachments)
    }

    private func commit() {
        guard let trip = syncEngine.trip else { return }
        // Obtain draft and selected IDs atomically from the current published
        // session. The button's `draft`/`selected` values belong to an earlier
        // SwiftUI render and can be stale after a streaming turn completes.
        guard let snapshot = store.commitSnapshot() else {
            error = "当前没有可确认的候选，请重新选择后确认。"
            return
        }
        guard snapshot.selected.allSatisfy(\.isCommitReady) else {
            error = "选中的候选信息尚未完整，请等待地点验证完成后再确认。"
            return
        }

        isCommitting = true
        Task {
            do {
                _ = try await client.commitAgentV2(
                    .init(
                        sessionId: store.session.id,
                        expectedTripVersion: trip.version,
                        timeZone: TimeZone.current.identifier,
                        selectedCandidateIds: snapshot.selected.map(\.id),
                        draft: snapshot.draft
                    ),
                    idempotencyKey: UUID()
                )
                store.clearCommittedDraft()
                await syncEngine.refresh()
            } catch {
                self.error = error.localizedDescription
            }
            self.isCommitting = false
        }
    }
}

private struct ChatMessageView: View {
    let message: AgentV2TurnRequest.Message

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 54)
                Text(message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
        } else {
            AssistantMessageContainer {
                Text(message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AssistantMessageContainer<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.indigo.gradient).frame(width: 28, height: 28)
                Image(systemName: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.white)
            }
            content
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LiveCandidateCard: View {
    let card: AgentV2LiveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(card.title).font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView().controlSize(.mini)
            }
            if !card.timing.isEmpty { Label(card.timing, systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            if let place = card.place { Label(place, systemImage: "mappin.and.ellipse").font(.caption) }
            if let reason = card.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Text("地点验证中").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct AgentV2CandidateCard: View {
    let candidate: AgentV2Candidate
    let selection: (Bool) -> Void

    var body: some View {
        Button { if candidate.isCommitReady { selection(!candidate.selected) } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(candidate.selected ? .indigo : .secondary)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.indigo)
                        Spacer()
                        Text(candidate.startAt).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(candidate.title).font(.headline).foregroundStyle(.primary)
                    Text(candidate.date + (candidate.place.map { " · \($0.name)" } ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let address = candidate.place?.address, !address.isEmpty {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = candidate.reason {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !candidate.risks.isEmpty {
                        Label(candidate.risks.joined(separator: "、"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: candidate.placeStatus == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        Text(candidate.placeStatus.title)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(candidate.placeStatus == .verified ? .green : .orange)
                }
            }
            .padding(13)
            .background(candidate.selected ? Color.indigo.opacity(0.09) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(candidate.selected ? Color.indigo.opacity(0.45) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .opacity(candidate.isCommitReady ? 1 : 0.72)
        .accessibilityValue(candidate.selected ? "已选择" : "未选择")
        .accessibilityHint(candidate.isCommitReady ? "轻点切换选择" : "信息完整后才可选择")
    }
}

private struct AgentContextSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var store: AgentV2SessionStore
    @Environment(\.dismiss) private var dismiss

    private let interests = ["美食", "文化", "自然", "购物", "拍照", "夜生活"]

    var body: some View {
        NavigationStack {
            Form {
                Section("本次旅行") {
                    if let trip = syncEngine.trip, trip.isConfigured {
                        LabeledContent("目的地", value: trip.destination ?? "待设置")
                        LabeledContent("日期", value: "\(trip.startDate ?? "") – \(trip.endDate ?? "")")
                        LabeledContent("时区", value: TimeZone.current.identifier)
                    } else {
                        ContentUnavailableView("请先完成旅行设置", systemImage: "calendar.badge.exclamationmark", description: Text("Agent 需要目的地、日期和币种来检查地点与冲突。"))
                    }
                }

                Section("规划条件") {
                    Picker("节奏", selection: binding(\.pace)) {
                        Text("未设置").tag(""); Text("轻松").tag("relaxed"); Text("均衡").tag("balanced"); Text("特种兵").tag("packed")
                    }
                    Picker("同行人", selection: binding(\.companions)) {
                        Text("未设置").tag(""); Text("独自").tag("solo"); Text("情侣").tag("couple"); Text("带父母").tag("parents"); Text("带儿童").tag("children")
                    }
                    Picker("预算", selection: binding(\.budget)) {
                        Text("未设置").tag(""); Text("省钱").tag("value"); Text("适中").tag("balanced"); Text("品质优先").tag("premium")
                    }
                    TextField("本轮范围，例如第二天下午", text: binding(\.scope))
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(interests, id: \.self) { interest in
                            Button { toggleInterest(interest) } label: {
                                HStack(spacing: 5) {
                                    if store.session.preferences.interests.contains(interest) { Image(systemName: "checkmark") }
                                    Text(interest)
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(store.session.preferences.interests.contains(interest) ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(store.session.preferences.interests.contains(interest) ? Color.indigo : Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("偏好")
                } footer: {
                    Text("条件会保存在本机，并作为每轮对话的规划前提。")
                }
            }
            .navigationTitle("旅行与偏好")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>) -> Binding<String> {
        Binding(
            get: { store.session.preferences[keyPath: keyPath] ?? "" },
            set: { value in store.updatePreference(keyPath, value: value.isEmpty ? nil : value) }
        )
    }

    private func toggleInterest(_ interest: String) {
        store.toggleInterest(interest)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), points)
    }
}

private extension AgentV2Candidate.PlaceStatus {
    var title: String {
        switch self {
        case .verified: "地点已验证"
        case .pending: "地点验证中"
        case .failed: "地点待确认"
        case .notRequired: "无需地点"
        }
    }
}

private extension AgentV2Change {
    var operationTitle: String {
        switch operation {
        case .add: "新增"
        case .replace: "替换"
        case .remove: "移除"
        case .move: "移动"
        case .keep: "保留"
        }
    }
}

private extension AgentV2Change.Operation {
    var symbol: String {
        switch self {
        case .add: "plus.circle.fill"
        case .replace: "arrow.triangle.2.circlepath.circle.fill"
        case .remove: "minus.circle.fill"
        case .move: "arrow.up.arrow.down.circle.fill"
        case .keep: "pin.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .add: .green
        case .replace, .move: .orange
        case .remove: .red
        case .keep: .indigo
        }
    }
}

private extension TravelCardSnapshot.Kind {
    var agentTitle: String {
        switch self {
        case .activity: "活动"
        case .hotel: "酒店"
        case .flight: "航班"
        }
    }

    var agentSymbol: String {
        switch self {
        case .activity: "figure.walk"
        case .hotel: "bed.double.fill"
        case .flight: "airplane"
        }
    }
}
