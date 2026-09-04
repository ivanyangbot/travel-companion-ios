import Foundation
import SwiftUI

/// Ephemeral Fliggy realtime-search chip state for the current turn. Like
/// ``AgentV2RunState/status`` it is pure UI progress: it never enters the
/// persisted session, drafts, or the commit payload.
struct AgentV2FliggyProgress: Equatable {
    enum Phase: Equatable {
        case running
        case completed(ok: Bool, count: Int?)
    }
    var kind: AgentV2FliggySearchKind
    var term: String?
    var phase: Phase
}

/// Long-lived state for one in-flight Agent turn. ContentView owns this
/// object, so dismissing and reopening the sheet does not cancel or visually
/// reset an active conversation.
@MainActor
final class AgentV2RunState: ObservableObject {
    /// Keeps expanded reasoning useful without allowing an unbounded streaming
    /// transcript to make SwiftUI repeatedly lay out tens of thousands of
    /// characters. Preserve the opening context and the newest reasoning.
    private static let maximumPublishedReasoningCharacters = 8_000
    private static let preservedReasoningPrefixCharacters = 1_500
    @Published var status: String?
    @Published var reasoningSummary = ""
    @Published var streamingReply = ""
    @Published var liveCards: [AgentV2LiveCard] = []
    @Published var stagedSummaryText = ""
    @Published var error: String?
    @Published private(set) var isGenerating = false
    @Published var isCommitting = false
    @Published private(set) var fliggyProgress: AgentV2FliggyProgress?
    /// 「新建一段旅行」的临时规划模式：当前行程暂时保留，首页整体切换到
    /// AgentHomeView(plansNewTrip:)。放在共享 run state 而不是 TodayView 本地
    /// @State，是因为旅程列表模式也要触发同一状态——它先切回 .today section
    /// 再置位，TodayView 挂载时直接进入规划态。
    @Published private(set) var isPlanningNewTrip = false

    /// How long a successful Fliggy completion chip lingers before fading
    /// out. Injectable so tests can verify the fade without real waits.
    var fliggyFadeInterval: TimeInterval = 1.5
    private var fliggyFadeTask: Task<Void, Never>?
    /// SSE often delivers assistant text one token at a time. Publishing every
    /// token forces SwiftUI (and its accessibility tree) to rebuild at the same
    /// rate, so collect short bursts and publish at most once per frame budget.
    private var streamingReplyBuffer = ""
    private var streamingReplyFlushTask: Task<Void, Never>?
    /// Reasoning deltas can be substantially longer than reply deltas. When
    /// expanded, publishing every token forces Text to lay out the entire,
    /// ever-growing summary repeatedly. Coalesce them at a lower UI cadence.
    private var reasoningSummaryBuffer = ""
    private var reasoningSummaryFlushTask: Task<Void, Never>?

    private(set) var generationTask: Task<Void, Never>?
    private var generationID: UUID?

    func beginGeneration() -> UUID {
        generationTask?.cancel()
        let id = UUID()
        generationID = id
        isGenerating = true
        return id
    }

    func attach(_ task: Task<Void, Never>, id: UUID) {
        guard generationID == id else { task.cancel(); return }
        generationTask = task
    }

    func finishGeneration(id: UUID) {
        guard generationID == id else { return }
        generationID = nil
        generationTask = nil
        isGenerating = false
        status = nil
        clearFliggyProgress()
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationID = nil
        generationTask = nil
        isGenerating = false
        status = nil
        clearFliggyProgress()
    }

    func prepareForTurn() {
        resetStreamingReply()
        resetReasoningSummary()
        stagedSummaryText = ""
        liveCards = []
        status = "正在理解你的需求…"
        error = nil
        clearFliggyProgress()
    }

    /// A disconnected durable turn resumes after its last received SSE ID.
    /// Keep the partial render in place; the server only replays newer events.
    func prepareForReconnect(attempt: Int, maximumAttempts: Int) {
        error = nil
        // Durable turns are intentionally safe to resume. Keep the last
        // meaningful server progress text instead of presenting a normal SSE
        // rollover or a brief mobile-network handoff as a failed operation.
        if status == nil || status?.isEmpty == true {
            status = "仍在处理，正在同步最新进度…"
        }
    }

    func discardPartialResponse() {
        resetStreamingReply()
        resetReasoningSummary()
        stagedSummaryText = ""
        liveCards = []
        error = nil
        status = nil
        clearFliggyProgress()
    }

    func clearTransientState() {
        cancelGeneration()
        resetStreamingReply()
        resetReasoningSummary()
        stagedSummaryText = ""
        liveCards = []
        error = nil
        isCommitting = false
        clearFliggyProgress()
    }

    /// 进入「新建一段旅行」规划模式：清掉进行中的回合并开新会话。首页地图
    /// 模式（切换旅行弹窗）与旅程列表模式（新建旅程入口）共用同一入口，
    /// 保证两个入口行为一致。
    func beginNewTripPlanning() {
        clearTransientState()
        isPlanningNewTrip = true
    }

    /// 退出规划模式：取消规划（左上角返回）与确认创建行程共用。
    func endNewTripPlanning() {
        isPlanningNewTrip = false
    }

    func appendStreamingReply(_ text: String) {
        guard !text.isEmpty else { return }
        streamingReplyBuffer += text
        guard streamingReplyFlushTask == nil else { return }

        streamingReplyFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.flushStreamingReply()
        }
    }

    /// Makes buffered text visible before `.done` persists the completed reply.
    func flushStreamingReply() {
        streamingReplyFlushTask?.cancel()
        streamingReplyFlushTask = nil
        guard !streamingReplyBuffer.isEmpty else { return }
        streamingReply += streamingReplyBuffer
        streamingReplyBuffer = ""
    }

    func appendReasoningSummary(_ text: String) {
        guard !text.isEmpty else { return }
        reasoningSummaryBuffer += text
        guard reasoningSummaryFlushTask == nil else { return }

        reasoningSummaryFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.flushReasoningSummary()
        }
    }

    func flushReasoningSummary() {
        reasoningSummaryFlushTask?.cancel()
        reasoningSummaryFlushTask = nil
        guard !reasoningSummaryBuffer.isEmpty else { return }
        let combined = reasoningSummary + reasoningSummaryBuffer
        if combined.count > Self.maximumPublishedReasoningCharacters {
            let suffixCount = Self.maximumPublishedReasoningCharacters
                - Self.preservedReasoningPrefixCharacters
            reasoningSummary = String(combined.prefix(Self.preservedReasoningPrefixCharacters))
                + "\n…\n"
                + String(combined.suffix(suffixCount))
        } else {
            reasoningSummary = combined
        }
        reasoningSummaryBuffer = ""
    }

    private func resetStreamingReply() {
        streamingReplyFlushTask?.cancel()
        streamingReplyFlushTask = nil
        streamingReplyBuffer = ""
        streamingReply = ""
    }

    private func resetReasoningSummary() {
        reasoningSummaryFlushTask?.cancel()
        reasoningSummaryFlushTask = nil
        reasoningSummaryBuffer = ""
        reasoningSummary = ""
    }

    // MARK: - Fliggy realtime-search chip

    /// A tool call started. Overwrites any lingering completion chip so
    /// back-to-back Fliggy calls always animate from a fresh running state.
    func fliggySearchStarted(_ start: AgentV2FliggySearchStart) {
        clearFliggyProgress()
        withAnimation(.easeInOut(duration: 0.2)) {
            fliggyProgress = AgentV2FliggyProgress(
                kind: AgentV2FliggySearchKind(raw: start.searchType),
                term: start.searchTerm,
                phase: .running
            )
        }
    }

    /// A tool call finished. `ok == true` shows the result count and fades
    /// the chip out after ``fliggyFadeInterval``; `ok == false` keeps the
    /// degradation notice visible until the turn ends — the model falls back
    /// to other sources and the stream keeps flowing, so this is never an
    /// error state.
    func fliggySearchCompleted(_ completion: AgentV2FliggySearchCompletion) {
        let previousTerm = fliggyProgress?.term
        clearFliggyProgress()
        withAnimation(.easeInOut(duration: 0.2)) {
            fliggyProgress = AgentV2FliggyProgress(
                kind: AgentV2FliggySearchKind(raw: completion.searchType),
                term: previousTerm,
                phase: .completed(ok: completion.ok, count: completion.count)
            )
        }
        guard completion.ok else { return }
        fliggyFadeTask = Task { [weak self, interval = fliggyFadeInterval] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.fliggyProgress = nil
            }
        }
    }

    func clearFliggyProgress() {
        fliggyFadeTask?.cancel()
        fliggyFadeTask = nil
        fliggyProgress = nil
    }
}

/// Drafts are deliberately kept outside the shared trip store.  This gives a
/// user reliable retry/resume behavior without exposing unconfirmed plans to a
/// collaborator or the backend.
@MainActor
final class AgentV2SessionStore: ObservableObject {
    @Published private(set) var session: AgentV2LocalSession
    /// Past conversations archived by "新建对话" or a fresh app launch, newest
    /// first. Local-only, like the active session: nothing here is ever sent
    /// to the backend unless the user restores a conversation and continues it.
    @Published private(set) var archives: [AgentV2LocalSession] = []

    private let defaults: UserDefaults
    private let key = "agent.v2.local.session"
    private let archivesKey = "agent.v2.local.archives"
    /// 每个旅程一套「旅行与偏好」规划条件：切换行程时把当前偏好存回旧旅程
    /// 的槽位，再载入新旅程的槽位。无生效行程（plan_new / 暂不选择行程）
    /// 使用独立槽位，同样不与其他旅程互通。
    private let tripPreferencesKey = "agent.v2.trip.preferences"
    private let activeTripKeyStorageKey = "agent.v2.trip.preferences.active"
    private var tripPreferences: [String: AgentV2TurnRequest.Preferences] = [:]
    private var activeTripKey: String?
    /// “暂不选择行程”对应的偏好槽位。
    private static let noTripPreferencesKey = "none"
    /// How many past conversations are kept on-device.
    static let archiveLimit = 20
    private var isReceivingNewTurn = false
    private var hasStagedResult = false
    private var stagedSummary: AgentV2Summary?
    private var stagedDraft: AgentV2Draft?
    private var stagedProposal: AgentV2TripProposal?

    /// - Parameter startsFreshOnLaunch: 每次冷启动都从全新会话开始——上次
    ///   有内容的对话自动归档进「历史对话」，主界面（首页 Agent 与工作台）
    ///   不再直接展示上一次的聊天记录；偏好随新会话延续。应用内切换页面、
    ///   收起再展开工作台不受影响。
    init(defaults: UserDefaults = .standard, startsFreshOnLaunch: Bool = false) {
        self.defaults = defaults
        if let data = defaults.data(forKey: archivesKey),
           let decodedArchives = try? JSONDecoder.agentV2.decode([AgentV2LocalSession].self, from: data) {
            archives = decodedArchives
        }
        if let data = defaults.data(forKey: tripPreferencesKey),
           let decodedMap = try? JSONDecoder.agentV2.decode([String: AgentV2TurnRequest.Preferences].self, from: data) {
            tripPreferences = decodedMap
        }
        activeTripKey = defaults.string(forKey: activeTripKeyStorageKey)
        if let data = defaults.data(forKey: key), var decoded = try? JSONDecoder.agentV2.decode(AgentV2LocalSession.self, from: data) {
            decoded.preferences.allowUnverifiedRecommendations = true
            let originalDraft = decoded.draft
            decoded.draft = originalDraft.map { $0.sanitizedForPersistence() }
            if decoded.draft?.candidates.isEmpty == true && decoded.draft?.changes.isEmpty == true {
                decoded.draft = nil
                decoded.summary = nil
            }
            session = decoded
            if decoded.draft != originalDraft {
                persist(touchUpdatedAt: false)
            }
        } else {
            session = .empty
        }
        if startsFreshOnLaunch, currentSessionHasContent {
            startNewSession()
        }
    }

    func save() {
        persist(touchUpdatedAt: true)
    }

    private func persist(touchUpdatedAt: Bool) {
        if touchUpdatedAt { session.updatedAt = .now }
        guard let data = try? JSONEncoder.agentV2.encode(session) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        resetStaging()
        session = .empty
        defaults.removeObject(forKey: key)
    }

    // MARK: - Conversation history

    /// A session worth archiving holds at least one message or draft.
    var currentSessionHasContent: Bool {
        !session.messages.isEmpty || session.draft != nil
    }

    /// Archives the current conversation (when it has content) and starts a
    /// fresh session. Preferences carry over; the archived conversation can
    /// be restored from the history list.
    func startNewSession() {
        archiveCurrentSessionIfNeeded()
        resetStaging()
        session = AgentV2LocalSession(
            id: UUID(),
            updatedAt: .now,
            preferences: session.preferences,
            messages: [],
            attachments: [],
            draft: nil,
            summary: nil
        )
        save()
    }

    /// Makes an archived conversation active again. The current conversation
    /// takes the archive's slot in the history list so nothing is lost.
    func restoreSession(id: UUID) {
        guard let index = archives.firstIndex(where: { $0.id == id }) else { return }
        let restored = archives.remove(at: index)
        persistArchives()
        archiveCurrentSessionIfNeeded()
        resetStaging()
        session = restored
        save()
    }

    func deleteArchivedSession(id: UUID) {
        archives.removeAll { $0.id == id }
        persistArchives()
    }

    private func archiveCurrentSessionIfNeeded() {
        guard currentSessionHasContent else { return }
        archives.removeAll { $0.id == session.id }
        archives.insert(session, at: 0)
        if archives.count > Self.archiveLimit {
            archives = Array(archives.prefix(Self.archiveLimit))
        }
        persistArchives()
    }

    private func persistArchives() {
        guard let data = try? JSONEncoder.agentV2.encode(archives) else { return }
        defaults.set(data, forKey: archivesKey)
    }

    func append(_ message: AgentV2TurnRequest.Message) {
        session.messages.append(message)
        save()
    }

    /// Appends a user message and atomically transfers the attachments used by
    /// its request out of the composer. Once submitted, those attachments are
    /// message content even while the assistant is still streaming or if the
    /// request is later cancelled.
    func append(_ message: AgentV2TurnRequest.Message, consumingAttachments attachments: [AgentV2TurnRequest.Attachment]) {
        session.messages.append(message)
        guard !attachments.isEmpty else {
            save()
            return
        }

        var groups = session.messageAttachmentGroups ?? []
        groups.removeAll { $0.messageID == message.id }
        groups.append(.init(messageID: message.id, attachments: attachments))
        session.messageAttachmentGroups = groups

        let submittedIDs = Set(attachments.map(\.id))
        session.attachments.removeAll { submittedIDs.contains($0.id) }
        save()
    }

    /// Starts an in-memory transaction for a streamed turn. Durable session
    /// state is left untouched until the server emits `done`.
    func beginTurn() {
        isReceivingNewTurn = true
        hasStagedResult = false
        stagedSummary = nil
        stagedDraft = nil
        stagedProposal = nil
    }

    /// Atomically publishes the fully received turn. Unconfirmed candidates
    /// from the previous draft carry forward unless this run's changes retire
    /// them via `targetDraftId` (replace → superseded, remove → discarded);
    /// drafts the model leaves untouched persist into the next turn so the
    /// user can confirm them later.
    func completeTurn() {
        guard isReceivingNewTurn else { return }
        if hasStagedResult {
            var completed = session
            completed.summary = stagedSummary
            if let stagedDraft {
                let previous = completed.draft
                // Drafts retired by this run: replace/remove with a targetDraftId
                // that matches a previous candidate. replace carries a new
                // candidateId (the staged supersedent) which is already in
                // stagedDraft.candidates, so only retire the old id.
                let retiredIDs = Set(stagedDraft.changes.compactMap { change in
                    (change.operation == .replace || change.operation == .remove)
                        ? change.targetDraftId : nil
                })
                var mergedCandidates = stagedDraft.candidates
                var mergedChanges = stagedDraft.changes
                if let previous {
                    let newIDs = Set(mergedCandidates.map(\.id))
                    // Carry forward untouched previous candidates behind the new
                    // ones so the newest proposals stay at the top of the list.
                    let carried = previous.candidates.filter { !retiredIDs.contains($0.id) && !newIDs.contains($0.id) }
                    mergedCandidates.append(contentsOf: carried)
                    let carriedIDs = Set(carried.map(\.id))
                    let referencedCandidateIDs = Set(mergedChanges.compactMap(\.candidateId))
                    let referencedCardIDs = Set(mergedChanges.compactMap(\.targetCardId))
                    for change in previous.changes {
                        if let candidateID = change.candidateId {
                            // Keep a carried candidate's pending add/replace
                            // intent unless this restated it.
                            if carriedIDs.contains(candidateID), !referencedCandidateIDs.contains(candidateID) {
                                mergedChanges.append(change)
                            }
                        } else if let cardID = change.targetCardId {
                            // Pending card-level proposals (e.g. an uncommitted
                            // remove) survive across turns until confirmed.
                            if !referencedCardIDs.contains(cardID) {
                                mergedChanges.append(change)
                            }
                        }
                        // targetDraftId-only changes from previous turns were
                        // applied in their own merge; drop them here.
                    }
                }
                // This turn's draft-targeting removals stay in the list so the
                // change list explains why a card disappeared; they are
                // informational only (server ignores them at commit) and are
                // dropped by the next turn's merge above.
                let previousSelectedIDs = Set(previous?.candidates.filter(\.selected).map(\.id) ?? [])
                completed.lastTurnCandidateIDs = stagedDraft.candidates.map(\.id)
                completed.draft = normalized(AgentV2Draft(candidates: mergedCandidates, changes: mergedChanges))
                // Carry forward the user's selection into the merged draft.
                // Candidates that survive sanitization and existed in the
                // previous draft keep their selected state.
                if var draft = completed.draft, !previousSelectedIDs.isEmpty {
                    for index in draft.candidates.indices where previousSelectedIDs.contains(draft.candidates[index].id) {
                        draft.candidates[index].selected = true
                    }
                    completed.draft = draft
                }
            }
            // A turn that produced no candidates/changes (pure Q&A) leaves the
            // previous unconfirmed draft intact instead of discarding it.
            if let stagedProposal {
                // 新一轮提案覆盖旧提案；未产出提案的轮次保留原有待确认提案。
                completed.pendingProposal = stagedProposal
            }
            session = completed
            save()
        }
        resetStaging()
    }

    /// Cancellation, an SSE error, or a connection ending without `done`
    /// simply drops staging and preserves the last persisted good result.
    func discardTurn() {
        resetStaging()
    }

    func apply(_ event: AgentV2StreamEvent) {
        guard isReceivingNewTurn else { return }
        switch event {
        case .summary(let summary):
            hasStagedResult = true
            stagedSummary = summary
        case .candidateUpsert(var candidate):
            hasStagedResult = true
            var draft = stagedDraft ?? AgentV2Draft(candidates: [], changes: [])
            // Preserve the user's selection when the server re-emits a candidate
            // that already exists in the draft (e.g. a candidate_patch or a
            // re-verification upsert). The server always sends selected=false;
            // overwriting would silently lose the user's intent.
            if let index = draft.candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidate.selected = draft.candidates[index].selected
                draft.candidates[index] = candidate
            } else {
                draft.candidates.append(candidate)
            }
            stagedDraft = draft
        case .candidatePatch(let id, var candidate):
            hasStagedResult = true
            var draft = stagedDraft ?? AgentV2Draft(candidates: [], changes: [])
            if let index = draft.candidates.firstIndex(where: { $0.id == id }) {
                candidate.selected = draft.candidates[index].selected
                draft.candidates[index] = candidate
            } else {
                draft.candidates.append(candidate)
            }
            stagedDraft = draft
        case .changeSet(let changes):
            hasStagedResult = true
            var draft = stagedDraft ?? AgentV2Draft(candidates: [], changes: [])
            draft.changes = changes
            stagedDraft = draft
        case .tripProposal(let proposal):
            hasStagedResult = true
            stagedProposal = proposal
        default: break
        }
    }

    private func resetStaging() {
        isReceivingNewTurn = false
        hasStagedResult = false
        stagedSummary = nil
        stagedDraft = nil
        stagedProposal = nil
    }

    private func normalized(_ draft: AgentV2Draft) -> AgentV2Draft? {
        let sanitized = draft.sanitizedForPersistence()
        return sanitized.candidates.isEmpty && sanitized.changes.isEmpty ? nil : sanitized
    }

    /// A direct user tap may promote an informational suggestion to an add.
    /// Existing-card proposals retain their original operation and target.
    func selectForImport(_ selected: Bool, id: UUID) {
        guard var draft = session.draft,
              draft.candidates.contains(where: { $0.id == id }) else { return }
        if selected && !draft.actionableCandidateIDs.contains(id) {
            guard !draft.changes.contains(where: { $0.candidateId == id && $0.targetCardId != nil }) else { return }
            draft.changes.removeAll { $0.candidateId == id }
            draft.changes.append(AgentV2Change(id: UUID(), operation: .add, candidateId: id,
                targetCardId: nil, summary: String(localized: "agent.joinTrip"), impact: nil))
            session.draft = draft
        }
        setSelected(selected, id: id)
    }

    func setSelected(_ selected: Bool, id: UUID) {
        guard var draft = session.draft,
              draft.actionableCandidateIDs.contains(id),
              let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].selected = selected
        session.draft = draft
        save()
    }

    func setSelected(_ selected: Bool, ids: Set<UUID>) {
        guard var draft = session.draft, !ids.isEmpty else { return }
        let actionableIDs = draft.actionableCandidateIDs
        for index in draft.candidates.indices
        where ids.contains(draft.candidates[index].id)
            && actionableIDs.contains(draft.candidates[index].id) {
            draft.candidates[index].selected = selected
        }
        session.draft = draft
        save()
    }

    /// Returns one coherent commit payload from the current published draft.
    /// The workbench must not submit candidates captured by an earlier SwiftUI
    /// render: a completed stream can replace `session.draft` between a card
    /// tap and the confirm-button action.
    func commitSnapshot() -> (draft: AgentV2Draft, selected: [AgentV2Candidate])? {
        guard let draft = session.draft else { return nil }
        let actionableIDs = draft.actionableCandidateIDs
        let selected = draft.candidates.filter { $0.selected && actionableIDs.contains($0.id) }
        // A pure-removal commit (no selected candidates but at least one
        // pending remove targeting a committed trip card) is valid too.
        let hasPendingRemoval = draft.changes.contains { $0.operation == .remove && $0.targetCardId != nil }
        guard !selected.isEmpty || hasPendingRemoval else { return nil }
        return (draft, selected)
    }

    func clearCommittedDraft() {
        discardTurn()
        session.draft = nil
        session.summary = nil
        session.attachments = []
        session.lastTurnCandidateIDs = nil
        save()
    }

    /// Remove only the candidates that the server actually committed. Any
    /// unselected or retryable candidate remains available for a later turn.
    func completeCommit(committedCandidateIDs: Set<UUID>) {
        discardTurn()
        guard var draft = session.draft else { return }
        draft.candidates.removeAll { committedCandidateIDs.contains($0.id) }
        draft.changes.removeAll { change in
            if change.operation == .remove, change.targetCardId != nil { return true }
            if let candidateID = change.candidateId, committedCandidateIDs.contains(candidateID) { return true }
            return false
        }
        for index in draft.candidates.indices {
            draft.candidates[index].selected = false
        }
        let remainingIDs = Set(draft.candidates.map(\.id))
        session.lastTurnCandidateIDs = session.lastTurnCandidateIDs?.filter(remainingIDs.contains)
        session.draft = normalized(draft)
        if session.draft == nil {
            session.attachments = []
            session.lastTurnCandidateIDs = nil
        }
        save()
    }

    /// Explicitly reject one local recommendation without changing the trip.
    func rejectCandidate(id: UUID) {
        guard var draft = session.draft else { return }
        draft.candidates.removeAll { $0.id == id }
        draft.changes.removeAll { $0.candidateId == id || $0.targetDraftId == id }
        session.lastTurnCandidateIDs?.removeAll { $0 == id }
        session.draft = normalized(draft)
        if session.draft == nil { session.lastTurnCandidateIDs = nil }
        save()
    }

    /// 用户确认提案并创建旅程后调用；此后的轮次回到旅程内（itinerary）模式。
    func clearPendingProposal() {
        session.pendingProposal = nil
        save()
    }

    /// 切换生效旅程时隔离「旅行与偏好」规划条件：当前偏好存回原旅程槽位，
    /// 载入目标旅程的槽位（首次使用该旅程时为全新默认值）。相同旅程重复
    /// 调用是幂等的。
    func activateTripPreferences(forTripID tripID: Int?) {
        let key = tripID.map(String.init) ?? Self.noTripPreferencesKey
        let previousKey = activeTripKey
        guard key != previousKey else { return }
        if let previousKey {
            tripPreferences[previousKey] = session.preferences
        }
        activeTripKey = key
        // 首次建立激活槽位（升级/重装后的第一次调用）时保留会话中现有偏好，
        // 避免一次性的设置丢失；此后每次切换都严格来自目标槽位。
        let fallback = previousKey == nil
            ? session.preferences
            : AgentV2TurnRequest.Preferences(pace: nil, companions: nil, budget: nil, interests: [])
        session.preferences = tripPreferences[key] ?? fallback
        persistTripPreferences()
        save()
    }

    private func persistTripPreferences() {
        defaults.set(activeTripKey, forKey: activeTripKeyStorageKey)
        guard let data = try? JSONEncoder.agentV2.encode(tripPreferences) else { return }
        defaults.set(data, forKey: tripPreferencesKey)
    }

    func updatePreference(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>, value: String?) {
        session.preferences[keyPath: keyPath] = value
        save()
    }

    func toggleInterest(_ interest: String) {
        if let index = session.preferences.interests.firstIndex(of: interest) {
            session.preferences.interests.remove(at: index)
        } else {
            session.preferences.interests.append(interest)
        }
        save()
    }

    func addAttachment(_ attachment: AgentV2TurnRequest.Attachment) {
        session.attachments.append(attachment)
        save()
    }

    func removeAttachment(id: UUID) {
        session.attachments.removeAll { $0.id == id }
        save()
    }

    func clearAttachments() {
        guard !session.attachments.isEmpty else { return }
        session.attachments.removeAll()
        save()
    }
}

private extension JSONEncoder {
    static var agentV2: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var agentV2: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
