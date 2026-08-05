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
        var scope: String?
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
    }

    var schemaVersion: Int = 2
    let sessionId: UUID
    let turnId: UUID
    let intent: String
    let message: String
    let trip: Trip
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

struct AgentV2Change: Codable, Sendable, Equatable, Identifiable {
    enum Operation: String, Codable, Sendable { case add, replace, remove, move, keep }
    let id: UUID
    var operation: Operation
    var candidateId: UUID?
    var targetCardId: Int?
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
    case done
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

    static let empty = AgentV2LocalSession(id: UUID(), updatedAt: .now, preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], scope: nil, allowUnverifiedRecommendations: true), messages: [], attachments: [], draft: nil, summary: nil)
}
