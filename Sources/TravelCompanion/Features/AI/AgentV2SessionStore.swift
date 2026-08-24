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
    @Published var status: String?
    @Published var reasoningSummary = ""
    @Published var streamingReply = ""
    @Published var liveCards: [AgentV2LiveCard] = []
    @Published var stagedSummaryText = ""
    @Published var error: String?
    @Published private(set) var isGenerating = false
    @Published var isCommitting = false
    @Published private(set) var fliggyProgress: AgentV2FliggyProgress?

    /// How long a successful Fliggy completion chip lingers before fading
    /// out. Injectable so tests can verify the fade without real waits.
    var fliggyFadeInterval: TimeInterval = 1.5
    private var fliggyFadeTask: Task<Void, Never>?

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
        streamingReply = ""
        reasoningSummary = ""
        stagedSummaryText = ""
        liveCards = []
        status = "正在理解你的需求…"
        error = nil
        clearFliggyProgress()
    }

    func clearTransientState() {
        cancelGeneration()
        streamingReply = ""
        reasoningSummary = ""
        stagedSummaryText = ""
        liveCards = []
        error = nil
        isCommitting = false
        clearFliggyProgress()
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

    private let defaults: UserDefaults
    private let key = "agent.v2.local.session"
    private var isReceivingNewTurn = false
    private var hasStagedResult = false
    private var stagedSummary: AgentV2Summary?
    private var stagedDraft: AgentV2Draft?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), var decoded = try? JSONDecoder.agentV2.decode(AgentV2LocalSession.self, from: data) {
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

    func append(_ message: AgentV2TurnRequest.Message) {
        session.messages.append(message)
        save()
    }

    /// Starts an in-memory transaction for a streamed turn. Durable session
    /// state is left untouched until the server emits `done`.
    func beginTurn() {
        isReceivingNewTurn = true
        hasStagedResult = false
        stagedSummary = nil
        stagedDraft = nil
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
        default: break
        }
    }

    private func resetStaging() {
        isReceivingNewTurn = false
        hasStagedResult = false
        stagedSummary = nil
        stagedDraft = nil
    }

    private func normalized(_ draft: AgentV2Draft) -> AgentV2Draft? {
        let sanitized = draft.sanitizedForPersistence()
        return sanitized.candidates.isEmpty && sanitized.changes.isEmpty ? nil : sanitized
    }

    func setSelected(_ selected: Bool, id: UUID) {
        guard var draft = session.draft, let index = draft.candidates.firstIndex(where: { $0.id == id }) else { return }
        draft.candidates[index].selected = selected
        session.draft = draft
        save()
    }

    func setSelected(_ selected: Bool, ids: Set<UUID>) {
        guard var draft = session.draft, !ids.isEmpty else { return }
        for index in draft.candidates.indices where ids.contains(draft.candidates[index].id) {
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
        let selected = draft.candidates.filter(\.selected)
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

    func updatePreference(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>, value: String?) {
        session.preferences[keyPath: keyPath] = value
        save()
    }

    func setAllowUnverifiedRecommendations(_ allowed: Bool) {
        session.preferences.allowUnverifiedRecommendations = allowed
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
