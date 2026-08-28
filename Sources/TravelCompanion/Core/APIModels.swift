import Foundation

struct APIEnvelope<Value: Decodable>: Decodable {
    let data: Value
    let meta: APIMeta?
}

struct AppleSignInRequest: Encodable, Sendable {
    let identityToken: String
    let fullName: String?
}

struct AppleSignInResult: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let id: Int
        let displayName: String?
        let email: String?
    }

    let accessToken: String
    let expiresIn: Int
    let user: User
    let isNewUser: Bool
}

struct APIWriteResponse: Decodable {
    let meta: APIMeta
}

struct APIMeta: Codable, Sendable {
    let tripVersion: Int
    let operationId: UUID?
    let conflict: Bool?
    let serverUpdatedAt: Date?
}

struct TripPatchRequest: Encodable, Sendable {
    var destination: String?
    var startDate: String?
    var endDate: String?
    var currency: String?
}

struct TripInvite: Decodable, Sendable {
    let id: Int
    let token: String
    let revoked: Bool
    let createdAt: Date
    let expiresAt: Date?
}

struct TripInviteRequest: Encodable, Sendable {
    let expiresInHours: Int?
}

struct TripJoinRequest: Encodable, Sendable {
    let token: String
}

struct TripMemberSummary: Decodable, Sendable, Identifiable, Equatable {
    let userId: Int
    let displayName: String?
    let email: String?
    let role: String
    let joinedAt: Date

    var id: Int { userId }
    var isOwner: Bool { role == "owner" }

    var visibleName: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        return isOwner ? String(localized: "member.ownerFallback") : String(localized: "member.fallback")
    }
}

struct TripSummary: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let destination: String?
    let startDate: String?
    let endDate: String?
    let currency: String?
    let version: Int
    let updatedAt: Date
    let role: String
    let joinedAt: Date

    var canShare: Bool { role == "owner" }

    var displayName: String {
        let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (destination?.isEmpty == false ? destination : nil) ?? String(localized: "common.unnamedTrip")
    }
}

struct DayRequest: Encodable, Sendable {
    let date: String
    let position: Int
}

struct PlaceRequest: Encodable, Sendable {
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var placeId: String?
    var cityCode: String? = nil
}

struct PlaceSearchResult: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
    let placeId: String?
    let cityCode: String? = nil

    var request: PlaceRequest {
        PlaceRequest(name: name, address: address, latitude: latitude, longitude: longitude, placeId: placeId, cityCode: cityCode)
    }
}

struct RoutePoint: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let cityCode: String?

    init(latitude: Double, longitude: Double, cityCode: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.cityCode = cityCode
    }
}

enum RouteMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case walking, driving, transit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .walking: String(localized: "mode.walking")
        case .driving: String(localized: "mode.driving")
        case .transit: String(localized: "mode.transit")
        }
    }
    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .driving: "car"
        case .transit: "bus"
        }
    }
}

struct RouteEstimateRequest: Encodable, Sendable {
    let origin: RoutePoint
    let destination: RoutePoint
    let mode: RouteMode
}

struct RouteEstimate: Codable, Sendable, Equatable {
    let distanceMeters: Int
    let durationSeconds: Int
    let mode: RouteMode
    let updatedAt: Date
    let source: String
}

struct RouteDirectionsRequest: Encodable, Sendable {
    let origin: RoutePoint
    let destination: RoutePoint
    let mode: RouteMode
}

struct RouteCoordinate: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct RouteDirections: Codable, Sendable, Equatable {
    let distanceMeters: Int
    let durationSeconds: Int
    let coordinates: [RouteCoordinate]
    let mode: RouteMode
    let updatedAt: Date
    let source: String
}

struct CardRequest: Encodable, Sendable {
    var dayId: Int?
    var kind: TravelCardSnapshot.Kind?
    var title: String?
    var startAt: String?
    var endAt: String?
    var place: PlaceRequest?
    var placeId: Int?
    var bookingCode: String?
    var url: String?
    var description: String?
    var fromAirport: String?
    var toAirport: String?
    var priceMinor: Int64?
    var actualPriceMinor: Int64?
    var ticketPriceMinor: Int64?
    var stayDurationMinutes: Int?
    var tips: [String]?
    var images: [String]?
    var notes: String?
    var position: Int?
    /// Names of nullable API fields deliberately cleared by a PATCH request.
    /// Swift's default optional encoding would otherwise send every absent field as null.
    var fieldsToClear: Set<String>

    init(
        dayId: Int? = nil,
        kind: TravelCardSnapshot.Kind? = nil,
        title: String? = nil,
        startAt: String? = nil,
        endAt: String? = nil,
        place: PlaceRequest? = nil,
        placeId: Int? = nil,
        bookingCode: String? = nil,
        url: String? = nil,
        description: String? = nil,
        fromAirport: String? = nil,
        toAirport: String? = nil,
        priceMinor: Int64? = nil,
        actualPriceMinor: Int64? = nil,
        ticketPriceMinor: Int64? = nil,
        stayDurationMinutes: Int? = nil,
        tips: [String]? = nil,
        images: [String]? = nil,
        notes: String? = nil,
        position: Int? = nil,
        fieldsToClear: Set<String> = []
    ) {
        self.dayId = dayId
        self.kind = kind
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.place = place
        self.placeId = placeId
        self.bookingCode = bookingCode
        self.url = url
        self.description = description
        self.fromAirport = fromAirport
        self.toAirport = toAirport
        self.priceMinor = priceMinor
        self.actualPriceMinor = actualPriceMinor
        self.ticketPriceMinor = ticketPriceMinor
        self.stayDurationMinutes = stayDurationMinutes
        self.tips = tips
        self.images = images
        self.notes = notes
        self.position = position
        self.fieldsToClear = fieldsToClear
    }

    enum CodingKeys: String, CodingKey { case dayId, kind, title, startAt, endAt, place, placeId, bookingCode, url, description, fromAirport, toAirport, priceMinor, actualPriceMinor, ticketPriceMinor, stayDurationMinutes, tips, images, notes, position }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(dayId, forKey: .dayId)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(startAt, forKey: .startAt)
        try encodeNullable(endAt, clearName: "endAt", key: .endAt, into: &container)
        try encodeNullable(place, clearName: "place", key: .place, into: &container)
        try container.encodeIfPresent(placeId, forKey: .placeId)
        try encodeNullable(bookingCode, clearName: "bookingCode", key: .bookingCode, into: &container)
        try encodeNullable(url, clearName: "url", key: .url, into: &container)
        try encodeNullable(description, clearName: "description", key: .description, into: &container)
        try encodeNullable(fromAirport, clearName: "fromAirport", key: .fromAirport, into: &container)
        try encodeNullable(toAirport, clearName: "toAirport", key: .toAirport, into: &container)
        try encodeNullable(priceMinor, clearName: "priceMinor", key: .priceMinor, into: &container)
        try encodeNullable(actualPriceMinor, clearName: "actualPriceMinor", key: .actualPriceMinor, into: &container)
        try encodeNullable(ticketPriceMinor, clearName: "ticketPriceMinor", key: .ticketPriceMinor, into: &container)
        try encodeNullable(stayDurationMinutes, clearName: "stayDurationMinutes", key: .stayDurationMinutes, into: &container)
        try encodeNullable(tips, clearName: "tips", key: .tips, into: &container)
        try encodeNullable(images, clearName: "images", key: .images, into: &container)
        try encodeNullable(notes, clearName: "notes", key: .notes, into: &container)
        try container.encodeIfPresent(position, forKey: .position)
    }

    private func encodeNullable<Value: Encodable>(_ value: Value?, clearName: String, key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else if fieldsToClear.contains(clearName) {
            try container.encodeNil(forKey: key)
        }
    }
}

struct ExpenseRequest: Encodable, Sendable {
    var amountMinor: Int64?
    var currency: String?
    var category: ExpenseCategory?
    var paidBy: ExpensePaidBy?
    var splitMode: ExpenseSplitMode?
    var occurredOn: String?
    var note: String?
    var cardID: Int?
    var fieldsToClear: Set<String>

    init(amountMinor: Int64? = nil, currency: String? = nil, category: ExpenseCategory? = nil, paidBy: ExpensePaidBy? = nil, splitMode: ExpenseSplitMode? = nil, occurredOn: String? = nil, note: String? = nil, cardID: Int? = nil, fieldsToClear: Set<String> = []) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = category
        self.paidBy = paidBy
        self.splitMode = splitMode
        self.occurredOn = occurredOn
        self.note = note
        self.cardID = cardID
        self.fieldsToClear = fieldsToClear
    }

    enum CodingKeys: String, CodingKey { case amountMinor, currency, category, paidBy, splitMode, occurredOn, note, cardID = "cardId" }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(amountMinor, forKey: .amountMinor)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(paidBy, forKey: .paidBy)
        try container.encodeIfPresent(splitMode, forKey: .splitMode)
        try container.encodeIfPresent(occurredOn, forKey: .occurredOn)
        try encodeNullable(note, clearName: "note", key: .note, into: &container)
        try encodeNullable(cardID, clearName: "cardId", key: .cardID, into: &container)
    }

    private func encodeNullable<Value: Encodable>(_ value: Value?, clearName: String, key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        if let value { try container.encode(value, forKey: key) }
        else if fieldsToClear.contains(clearName) { try container.encodeNil(forKey: key) }
    }
}

struct APIProblem: Decodable, Error, LocalizedError {
    struct Details: Decodable {
        let field: String
        let reason: String
        let candidateId: String?
    }
    let code: String
    let message: String
    let requestId: String
    let details: [Details]?
    var statusCode: Int?

    var errorDescription: String? {
        let displayMessage = switch code {
        case "place_verification_unavailable":
            String(localized: "error.placeVerificationUnavailable")
        default:
            message
        }
        guard let detail = details?.first, !detail.reason.isEmpty else { return displayMessage }
        return String(format: String(localized: "error.problemDetail"), displayMessage, detail.field, detail.reason)
    }

    var isPermanentClientFailure: Bool {
        guard let statusCode else { return false }
        return (400 ... 499).contains(statusCode) && statusCode != 429
    }
}

struct APIErrorEnvelope: Decodable {
    let error: APIProblem
}

/// Read-only snapshot of the trip's existing cards, sent so the AI can enrich
/// rather than duplicate what is already planned. Omitted entirely when the
/// trip has no cards yet.
struct AIExistingItineraryDay: Encodable, Sendable {
    let date: String
    let cards: [AIExistingItineraryCard]
}

struct AIExistingItineraryCard: Encodable, Sendable {
let kind: String
let title: String
let time: String?
let place: String?
let notes: String?
}

/// Agent 欢迎页「可以这样问」的三条动态建议请求：独立于 Agent v2 轮次管线的
/// 轻量一次性调用。行程快照作为只读上下文传入（与 Agent 轮次传入的行程上下文
/// 同构），服务端不持久化任何内容。
struct AITripSuggestionsRequest: Encodable, Sendable {
struct Preferences: Encodable, Sendable {
let pace: String?
let companions: String?
let budget: String?
let interests: [String]?
}
/// 建议模式：`nil`（即服务端默认 itinerary）表示围绕已有行程出建议；
/// `journey` 表示客户端没有生效行程，请服务端返回整段旅程规划类建议。
let mode: String?
let destination: String?
let startDate: String?
let endDate: String?
let currency: String?
let preferences: Preferences?
let existingItinerary: [AIExistingItineraryDay]?
}

struct AITripSuggestionsResult: Decodable, Sendable, Equatable {
let suggestions: [String]
/// 服务端为每条建议选择的 SF Symbol 图标（与 suggestions 一一对应）；
/// 旧版本后端可能不返回，客户端回退本地关键词图标。
let icons: [String]?
}

/// Stateless multi-turn itinerary chat: the client replays the full message
/// history each turn and receives an assistant reply plus a batch of proposed
/// itinerary cards (possibly empty while only discussing). Existing cards are
/// sent as read-only context so the model enriches rather than duplicates.
struct AIItineraryChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable, Equatable {
        let role: String
        let content: String
    }
    let messages: [Message]
    let startDate: String
    let days: Int
    /// Trip destination supplied to the model and on-device MapKit verification.
    /// It prevents ambiguous POI names from being resolved in another city.
    let destination: String?
    let preferences: String?
    let images: [String]?
    let existingItinerary: [AIExistingItineraryDay]?
}

struct AIItineraryChatResult: Decodable, Sendable, Equatable {
    let reply: String
    let cards: [AIItineraryDraft.Card]
}

/// One Server-Sent Event from the streaming itinerary-chat endpoint. The reply
/// text arrives as incremental ``reply`` deltas; the validated ``result``
/// (cards resolved to coordinates) arrives once at the end. Errors raised
/// mid-stream surface as ``AIItineraryStreamError`` thrown from the stream.
enum AIItineraryChatStreamEvent: Sendable {
    /// Model's chain-of-thought fragment, displayed in a distinct style.
    case thinking(String)
    case reply(String)
    /// A card's core fields; render the card UI as soon as this arrives.
    case card(index: Int, card: AIItineraryDraft.Card)
    /// Extended fields (description, price, flight info) for a streamed card.
    case cardUpdate(index: Int, extras: AICardExtras, notes: String?)
    /// Server-side Apple Maps verification outcome for a pending card.
    case cardPlace(index: Int, place: AIChatPlace?, verified: Bool)
    case result(AIItineraryChatResult)
}

/// Wire payload of a streamed ``cardPlace`` event.
struct AIItineraryStreamCardPlacePayload: Decodable, Sendable {
    let index: Int
    let place: AIChatPlace?
    let verified: Bool
}

/// Wire payload of a streamed ``card`` event (``{"index", "card"}``).
struct AIItineraryStreamCardPayload: Decodable, Sendable {
    let index: Int
    let card: AIItineraryDraft.Card
}

/// Wire payload of a streamed ``cardx`` event (``{"index", "fields"}``).
struct AIItineraryStreamCardUpdatePayload: Decodable, Sendable {
    let index: Int
    let fields: AICardExtrasWithNotes?
}

/// ``cardx`` fields; ``notes`` merges into the card's own notes, the rest
/// into its extras.
struct AICardExtrasWithNotes: Decodable, Sendable {
    let description: String?
    let url: String?
    let priceMinor: Int64?
    let bookingCode: String?
    let fromAirport: String?
    let toAirport: String?
    let notes: String?

    var extras: AICardExtras {
        AICardExtras(description: description, url: url, priceMinor: priceMinor, bookingCode: bookingCode, fromAirport: fromAirport, toAirport: toAirport)
    }
}

/// Server-emitted SSE error payload (``{"code","message"}``) for a streaming
/// turn that failed after the connection was established.
struct AIItineraryStreamError: Decodable, Error, LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct LinkImportRequest: Encodable, Sendable {
    let url: String
}

/// A single travel card drafted by the server from a Xiaohongshu note's
/// public Open Graph metadata. `place` is a free-text name; `imageUrl` is a
/// server-hosted relative path resolved against the API base URL.
struct LinkImportResult: Decodable, Sendable, Equatable {
    let kind: TravelCardSnapshot.Kind
    let title: String
    let place: String?
    let notes: String?
    let imageURL: String?
    let url: String

    enum CodingKeys: String, CodingKey { case kind, title, place, notes, imageURL = "imageUrl", url }
}

/// A place proposed by AI. Before the user imports it, the app resolves this
/// name with Apple MapKit and persists the resulting coordinate-backed POI.
struct AIChatPlace: Codable, Sendable, Equatable {
    let name: String
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let placeId: String?
    let cityCode: String?

    private enum CodingKeys: String, CodingKey {
        case name, address, latitude, longitude, placeId, cityCode
    }

    init(name: String, address: String?, latitude: Double?, longitude: Double?, placeId: String?, cityCode: String?) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.placeId = placeId
        self.cityCode = cityCode
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(), let name = try? singleValue.decode(String.self) {
            self.init(name: name, address: nil, latitude: nil, longitude: nil, placeId: nil, cityCode: nil)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            address: try container.decodeIfPresent(String.self, forKey: .address),
            latitude: try container.decodeIfPresent(Double.self, forKey: .latitude),
            longitude: try container.decodeIfPresent(Double.self, forKey: .longitude),
            placeId: try container.decodeIfPresent(String.self, forKey: .placeId),
            cityCode: try container.decodeIfPresent(String.self, forKey: .cityCode)
        )
    }
}

/// Extended AI card fields beyond the importable core. Streamed as a
/// ``cardx`` event right after the card's core fields, then persisted with
/// the confirmed draft so an offline import loses nothing.
struct AICardExtras: Codable, Sendable, Equatable {
    var description: String?
    var url: String?
    var priceMinor: Int64?
    var bookingCode: String?
    var fromAirport: String?
    var toAirport: String?

    var isEmpty: Bool {
        description == nil && url == nil && priceMinor == nil && bookingCode == nil && fromAirport == nil && toAirport == nil
    }

    mutating func merge(_ other: AICardExtras) {
        if let value = other.description { description = value }
        if let value = other.url { url = value }
        if let value = other.priceMinor { priceMinor = value }
        if let value = other.bookingCode { bookingCode = value }
        if let value = other.fromAirport { fromAirport = value }
        if let value = other.toAirport { toAirport = value }
    }
}

struct AIItineraryDraft: Codable, Sendable, Equatable {
    var days: [Day]

    struct Day: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        var date: String
        var cards: [Card]

        enum CodingKeys: String, CodingKey { case date, cards }

        init(date: String, cards: [Card]) {
            id = UUID()
            self.date = date
            self.cards = cards
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            cards = try container.decode([Card].self, forKey: .cards)
            id = UUID()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            try container.encode(cards, forKey: .cards)
        }
    }

    struct Card: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        var isSelected: Bool
        var kind: TravelCardSnapshot.Kind
        var title: String
        var date: String
        var time: String?
        var place: AIChatPlace?
        var notes: String?
        /// Extended draft fields (description, estimated price, flight details)
        /// streamed incrementally after the card's core fields arrive.
        var extras: AICardExtras?
        /// Transient streaming state: the card was rendered immediately while
        /// the server is still verifying its place against Apple Maps. Not
        /// part of the wire format (a ``cardPlace`` event resolves it).
        var placePending: Bool

        enum CodingKeys: String, CodingKey { case kind, title, date, time, place, notes, isSelected, extras, description, url, priceMinor, bookingCode, fromAirport, toAirport }

        init(kind: TravelCardSnapshot.Kind, title: String, date: String, time: String?, place: AIChatPlace?, notes: String?, isSelected: Bool = true, extras: AICardExtras? = nil, placePending: Bool = false) {
            id = UUID()
            self.isSelected = isSelected
            self.kind = kind
            self.title = title
            self.date = date
            self.time = time
            self.place = place
            self.notes = notes
            self.extras = extras
            self.placePending = placePending
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(TravelCardSnapshot.Kind.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            date = try container.decode(String.self, forKey: .date)
            time = try container.decodeIfPresent(String.self, forKey: .time)
            place = try container.decodeIfPresent(AIChatPlace.self, forKey: .place)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            id = UUID()
            // The server marks cards whose place failed Apple Maps verification
            // as not selected; default to selected for older payloads.
            isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
            placePending = false
            if let bundled = try container.decodeIfPresent(AICardExtras.self, forKey: .extras) {
                extras = bundled
            } else {
                // The server sends extended fields flat on the card object.
                let flat = AICardExtras(
                    description: try container.decodeIfPresent(String.self, forKey: .description),
                    url: try container.decodeIfPresent(String.self, forKey: .url),
                    priceMinor: try container.decodeIfPresent(Int64.self, forKey: .priceMinor),
                    bookingCode: try container.decodeIfPresent(String.self, forKey: .bookingCode),
                    fromAirport: try container.decodeIfPresent(String.self, forKey: .fromAirport),
                    toAirport: try container.decodeIfPresent(String.self, forKey: .toAirport)
                )
                extras = flat.isEmpty ? nil : flat
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(date, forKey: .date)
            try container.encodeIfPresent(time, forKey: .time)
            try container.encodeIfPresent(place, forKey: .place)
            try container.encodeIfPresent(notes, forKey: .notes)
            try container.encodeIfPresent(extras, forKey: .extras)
        }
    }

    var selectedCards: [Card] { days.flatMap(\.cards).filter(\.isSelected) }

    func validationMessage(startDate: String, days: Int) -> String? {
        guard let start = Self.dateFormatter.date(from: startDate), days > 0 else { return String(localized: "error.validation.dateUnset") }
        guard let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: days - 1, to: start) else { return String(localized: "error.validation.dateInvalid") }
        for card in selectedCards {
            let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1 ... 160).contains(title.count),
                  let date = Self.dateFormatter.date(from: card.date), date >= start, date <= end else {
                return String(localized: "error.validation.titleRange")
            }
            if let time = card.time, !time.isEmpty, !Self.timeIsValid(time) {
                return String(localized: "error.validation.timeFormat")
            }
            if let place = card.place, place.name.trimmingCharacters(in: .whitespacesAndNewlines).count > 160 {
                return String(localized: "error.validation.placeLength")
            }
            if let notes = card.notes, notes.trimmingCharacters(in: .whitespacesAndNewlines).count > 2_000 {
                return String(localized: "error.validation.noteLength")
            }
        }
        return selectedCards.isEmpty ? String(localized: "error.validation.noCards") : nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func timeIsValid(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0 ... 23).contains(hour) && (0 ... 59).contains(minute) && parts[0].count == 2 && parts[1].count == 2
    }
}

/// Stateless multi-turn request for the AI conversational expense flow. The
/// client owns the message history and replays it each turn; receipt photos
/// are inline base64 data URIs attached to the last user message.
struct AIExpenseConversationRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable, Equatable {
        let role: String
        let content: String
    }

    let dayDate: String
    let currency: String?
    let messages: [Message]
    let images: [String]?
}

/// One turn of the AI expense conversation. `expenseDraft` is the latest
/// structured draft (or nil while still collecting). `missingRequired` gates
/// confirmation. `cardId` is always nil from the model; the user picks the
/// linked card in the confirm sheet.
struct AIExpenseDraft: Decodable, Sendable, Equatable {
    let reply: String
    let expenseDraft: AIExpenseDraftCard?
    let missingRequired: [String]?

    enum CodingKeys: String, CodingKey { case reply, expenseDraft, missingRequired }
}

struct AIExpenseDraftCard: Decodable, Sendable, Equatable {
    let amountMinor: Int64?
    let currency: String?
    let category: ExpenseCategory?
    let occurredOn: String?
    let note: String?
    let cardId: Int?
}
