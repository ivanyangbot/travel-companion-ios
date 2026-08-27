import Foundation

/// Versioned, local-first contract for the PRD Agent workbench.  The server
/// receives an explicit snapshot each turn and never owns a conversation.
struct AgentV2TurnRequest: Codable, Sendable {
    struct Trip: Codable, Sendable {
        let destination: String?
        let startDate: String?
        let endDate: String?
        let currency: String?
        let timeZone: String
        let version: Int
        let days: [Day]
    }
    struct Day: Codable, Sendable {
        let date: String
        let cards: [Card]
    }
    struct Card: Codable, Sendable {
        let id: Int?
        let kind: String
        let title: String
        let startAt: String
        let endAt: String?
        let place: String?
        let notes: String?
    }
    struct Preferences: Codable, Sendable, Equatable {
        var pace: String?
        var companions: String?
        var budget: String?
        var interests: [String]
        var allowUnverifiedRecommendations: Bool? = nil

        var retainsUnverifiedRecommendations: Bool {
            allowUnverifiedRecommendations ?? true
        }
    }
    struct Message: Codable, Sendable, Identifiable {
        let id: UUID
        let role: String
        let content: String
        let createdAt: Date
    }
    struct Attachment: Codable, Sendable, Identifiable {
        let id: UUID
        let mediaType: String
        let dataURI: String
        let fileName: String?

        init(id: UUID, mediaType: String, dataURI: String, fileName: String? = nil) {
            self.id = id
            self.mediaType = mediaType
            self.dataURI = dataURI
            self.fileName = fileName
        }
    }

    var schemaVersion: Int = 2
    let sessionId: UUID
    let turnId: UUID
    let intent: String
    let message: String
    /// `nil` 表示 plan_new 轮次：用户还没有创建旅程，服务端会产出待确认的
    /// 旅程提案（trip_proposal 事件），提案确认前不会落库创建旅程。
    let trip: Trip?
    let preferences: Preferences
    let history: [Message]
    let activeDraft: AgentV2Draft?
    let attachments: [Attachment]
}

struct AgentV2Draft: Codable, Sendable, Equatable {
    var candidates: [AgentV2Candidate]
    var changes: [AgentV2Change]

    /// Only candidates that can safely be shown as a durable, selectable
    /// draft survive persistence. Streaming placeholders live in
    /// `AgentV2LiveCard` and must never leak into a resumed session.
    func sanitizedForPersistence() -> AgentV2Draft {
        let safeCandidates = candidates.filter(\.isSafeForPersistedDraft)
        let safeCandidateIDs = Set(safeCandidates.map(\.id))
        let safeChanges = changes.filter { change in
            guard let candidateID = change.candidateId else { return true }
            return safeCandidateIDs.contains(candidateID)
        }
        return AgentV2Draft(candidates: safeCandidates, changes: safeChanges)
    }
}

struct AgentV2Candidate: Codable, Sendable, Equatable, Identifiable {
    enum PlaceStatus: String, Codable, Sendable { case verified, pending, failed, notRequired }
    let id: UUID
    var kind: TravelCardSnapshot.Kind
    var title: String
    var sourceText: String? = nil
    var allowsUnverifiedPlace: Bool? = nil
    var date: String
    var startAt: String
    var endAt: String?
    var place: AIChatPlace?
    var placeStatus: PlaceStatus
    var description: String?
    var notes: String?
    var url: String?
    var sourceProof: String? = nil
    var priceMinor: Int64?
    var ticketPriceMinor: Int64?
    var stayDurationMinutes: Int?
    var tips: [String]
    var bookingCode: String?
    var fromAirport: String?
    var toAirport: String?
    var reason: String?
    var risks: [String]
    var missingFields: [String]
    var selected: Bool

    /// Activity and hotel drafts are only useful after the server has
    /// resolved a concrete Apple Maps result. Requiring the normalized name,
    /// display address and sane coordinates prevents old pending/failed or
    /// partially decoded candidates from reappearing after an app update.
    var hasConcreteVerifiedPlace: Bool {
        guard placeStatus == .verified, let place,
              !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let address = place.address,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let latitude = place.latitude, latitude.isFinite, (-90...90).contains(latitude),
              let longitude = place.longitude, longitude.isFinite, (-180...180).contains(longitude)
        else { return false }
        return true
    }

    /// A server-approved text-only itinerary item copied from the user's
    /// message. It is addable without inventing coordinates or a provider ID.
    var hasExplicitUnverifiedPlace: Bool {
        guard placeStatus == .failed, place == nil,
              let sourceText,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// The server marks this only after applying the user's current policy.
    /// The card remains text-only; no coordinates or provider identity are
    /// invented, and the user must still select it before commit.
    var hasAllowedUnverifiedPlace: Bool {
        placeStatus == .failed && place == nil && allowsUnverifiedPlace == true
    }

    var isSafeForPersistedDraft: Bool {
        kind != .activity && kind != .hotel || hasConcreteVerifiedPlace || hasExplicitUnverifiedPlace || hasAllowedUnverifiedPlace
    }

    var isCommitReady: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !date.isEmpty, !startAt.isEmpty else { return false }
        if kind == .activity || kind == .hotel {
            return hasConcreteVerifiedPlace || hasExplicitUnverifiedPlace || hasAllowedUnverifiedPlace
        }
        return kind != .flight || (bookingCode?.isEmpty == false && fromAirport?.isEmpty == false && toAirport?.isEmpty == false)
    }
}

extension AgentV2Candidate {
    /// Unscheduled POI-inquiry cards legitimately carry null `date`/`startAt`
    /// (the user picks a date later, or asks the agent to schedule them in a
    /// follow-up turn). Decode those as empty strings so one unscheduled card
    /// cannot abort the whole SSE stream at `candidate_upsert`. Defined in an
    /// extension so the memberwise initializer stays available for tests.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TravelCardSnapshot.Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)
        allowsUnverifiedPlace = try container.decodeIfPresent(Bool.self, forKey: .allowsUnverifiedPlace)
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        startAt = try container.decodeIfPresent(String.self, forKey: .startAt) ?? ""
        endAt = try container.decodeIfPresent(String.self, forKey: .endAt)
        place = try container.decodeIfPresent(AIChatPlace.self, forKey: .place)
        placeStatus = try container.decode(PlaceStatus.self, forKey: .placeStatus)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        sourceProof = try container.decodeIfPresent(String.self, forKey: .sourceProof)
        priceMinor = try container.decodeIfPresent(Int64.self, forKey: .priceMinor)
        ticketPriceMinor = try container.decodeIfPresent(Int64.self, forKey: .ticketPriceMinor)
        stayDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .stayDurationMinutes)
        tips = try container.decodeIfPresent([String].self, forKey: .tips) ?? []
        bookingCode = try container.decodeIfPresent(String.self, forKey: .bookingCode)
        fromAirport = try container.decodeIfPresent(String.self, forKey: .fromAirport)
        toAirport = try container.decodeIfPresent(String.self, forKey: .toAirport)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        missingFields = try container.decodeIfPresent([String].self, forKey: .missingFields) ?? []
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
    }
}

extension AgentV2TurnRequest {
    /// The server-side debug conversation caps history at 10 turns (20
    /// messages) and 2 000 characters per message. Mirror that here so a
    /// long-lived local session cannot grow the turn payload without bound.
    static func trimmedHistory(_ messages: [Message], limit: Int = 20, fieldLimit: Int = 2_000) -> [Message] {
        messages.suffix(limit).map { message in
            guard message.content.count > fieldLimit else { return message }
            return Message(id: message.id, role: message.role, content: String(message.content.prefix(fieldLimit)), createdAt: message.createdAt)
        }
    }
}

struct AgentV2Change: Codable, Sendable, Equatable, Identifiable {
    enum Operation: String, Codable, Sendable { case add, replace, remove, move, keep }
    let id: UUID
    var operation: Operation
    var candidateId: UUID?
    var targetCardId: Int?
    /// Unconfirmed draft candidate targeted by a replace/remove. Paired with
    /// `candidateId` for replace (the new candidate supersedes the draft) or
    /// nil for remove (discard the draft). Mutually exclusive with
    /// `targetCardId`, which only addresses already-committed trip cards.
    var targetDraftId: UUID? = nil
    var summary: String
    var impact: String?
}

struct AgentV2Summary: Codable, Sendable, Equatable {
    var text: String
    var coveredDates: [String]
    var pending: [String]
}

enum AgentV2StreamEvent: Sendable {
    case status(String)
    case reasoningSummary(String)
    case assistantDelta(String)
    case cardBegin(id: UUID, index: Int)
    case cardFieldDelta(id: UUID, field: String, value: String)
    case question(String)
    case summary(AgentV2Summary)
    case candidateUpsert(AgentV2Candidate)
    case candidatePatch(id: UUID, candidate: AgentV2Candidate)
    case changeSet([AgentV2Change])
    case tripProposal(AgentV2TripProposal)
    case fliggySearchStarted(AgentV2FliggySearchStart)
    case fliggySearchCompleted(AgentV2FliggySearchCompletion)
    case done
}

/// plan_new 轮次服务端下发的旅程提案。仅作展示与用户确认用途：确认前
/// 服务端不落库，确认后由客户端调用既有建旅程接口创建。
struct AgentV2TripProposal: Codable, Sendable, Equatable {
    let destination: String
    let startDate: String
    let endDate: String
    let currency: String
    let timeZone: String
}

/// Brand-structured progress signal emitted around each Fliggy realtime
/// tool call. Ephemeral UI progress only: it must never enter the persisted
/// session, drafts, or logs (see `AgentV2FliggySearchKind`).
struct AgentV2FliggySearchStart: Decodable, Sendable, Equatable {
    let searchType: String
    private let query: String?
    private let destName: String?
    private let origin: String?
    private let destination: String?
    private let cityName: String?

    /// The first non-empty search term the model filled in (server caps it at
    /// 120 characters; the client truncates defensively for display).
    var searchTerm: String? {
        for value in [query, destName, origin, destination, cityName] {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return String(trimmed.prefix(120))
        }
        return nil
    }
}

/// Terminal signal for one Fliggy tool call. `ok == false` means Fliggy was
/// unavailable/rate-limited and the model degrades gracefully; the stream
/// keeps flowing and the client must not treat it as an error.
struct AgentV2FliggySearchCompletion: Decodable, Sendable, Equatable {
    let searchType: String
    let ok: Bool
    let count: Int?
}

/// `searchType` of a Fliggy search notification. Unknown server values fall
/// back to `other` so newer/older servers stay renderable without throwing.
enum AgentV2FliggySearchKind: String, Sendable, Equatable {
    case fast
    case ai
    case hotel
    case flight
    case train
    case poi
    case other

    init(raw: String) {
        self = Self(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }

    /// Chip copy while the search is running.
    var progressTitle: String {
        switch self {
        case .hotel: "正在查询飞猪酒店实时价格"
        case .flight: "正在查询机票实时价格"
        case .train: "正在查询火车票实时价格"
        case .poi: "正在查询景点门票实时价格"
        case .fast, .ai, .other: "正在查询飞猪实时库存"
        }
    }
}

/// Ephemeral, field-by-field card state for the current streaming turn.
/// It is deliberately separate from a confirmable draft until the server has
/// validated the whole candidate and its Apple Maps POI.
struct AgentV2LiveCard: Identifiable, Equatable {
    let id: UUID
    let index: Int
    var fields: [String: String] = [:]

    var title: String { fields["title"] ?? "正在整理候选…" }
    var timing: String {
        [fields["date"], fields["startAt"]].compactMap { $0 }.joined(separator: " · ")
    }
    var place: String? { fields["placeQuery"] }
    var reason: String? { fields["reason"] }
}

struct AgentV2CommitRequest: Codable, Sendable {
    var schemaVersion: Int = 2
    let sessionId: UUID
    let expectedTripVersion: Int
    let timeZone: String
    let selectedCandidateIds: [UUID]
    let draft: AgentV2Draft
}

struct AgentV2CommitResult: Codable, Sendable {
    let tripVersion: Int
    let committedCandidateIds: [UUID]
}

struct AgentV2LocalSession: Codable, Identifiable {
    var id: UUID
    var updatedAt: Date
    var preferences: AgentV2TurnRequest.Preferences
    var messages: [AgentV2TurnRequest.Message]
    var attachments: [AgentV2TurnRequest.Attachment]
    var draft: AgentV2Draft?
    var summary: AgentV2Summary?
    /// Candidate ids produced by the most recent completed turn. Other draft
    /// candidates carried forward from earlier turns and render in a separate
    /// "still pending" group. Optional so sessions persisted by older builds
    /// decode cleanly (nil = treat every candidate as current-turn).
    var lastTurnCandidateIDs: [UUID]? = nil
    /// plan_new 会话中待用户确认的旅程提案；确认创建旅程后清除。Optional so
    /// sessions persisted by older builds decode cleanly.
    var pendingProposal: AgentV2TripProposal? = nil

    static let empty = AgentV2LocalSession(id: UUID(), updatedAt: .now, preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], allowUnverifiedRecommendations: true), messages: [], attachments: [], draft: nil, summary: nil)
}
