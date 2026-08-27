import Foundation
import SwiftData

struct SharedTripSnapshot: Codable, Sendable, Equatable {
    let id: Int
    var destination: String?
    var startDate: String?
    var endDate: String?
    var currency: String?
    var version: Int
    var updatedAt: Date
    var days: [TripDaySnapshot]
    var expenses: [ExpenseSnapshot]

    enum CodingKeys: String, CodingKey { case id, destination, startDate, endDate, currency, version, updatedAt, days, expenses }

    init(id: Int, destination: String?, startDate: String?, endDate: String?, currency: String?, version: Int, updatedAt: Date, days: [TripDaySnapshot], expenses: [ExpenseSnapshot] = []) {
        self.id = id
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
        self.currency = currency
        self.version = version
        self.updatedAt = updatedAt
        self.days = days
        self.expenses = expenses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        version = try container.decode(Int.self, forKey: .version)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        days = try container.decodeIfPresent([TripDaySnapshot].self, forKey: .days) ?? []
        expenses = try container.decodeIfPresent([ExpenseSnapshot].self, forKey: .expenses) ?? []
    }

    var isConfigured: Bool {
        destination?.isEmpty == false && startDate != nil && endDate != nil && currency != nil
    }
}

struct ExpenseSnapshot: Codable, Sendable, Equatable, Identifiable {
    /// Local identity lets an offline record render before the server assigns an integer ID.
    let id: UUID
    var serverID: Int?
    var amountMinor: Int64
    var currency: String
    var category: ExpenseCategory
    /// Retained by the server for historical rows but no longer part of the
    /// contract; the UI never models splitting.
    var paidBy: ExpensePaidBy?
    var splitMode: ExpenseSplitMode?
    var occurredOn: String
    var note: String?
    var cardID: Int?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey { case serverID = "id", localID, amountMinor, currency, category, paidBy, splitMode, occurredOn, note, cardID = "cardId", updatedAt }

    init(serverID: Int? = nil, amountMinor: Int64, currency: String, category: ExpenseCategory, paidBy: ExpensePaidBy? = nil, splitMode: ExpenseSplitMode? = nil, occurredOn: String, note: String? = nil, cardID: Int? = nil, updatedAt: Date = .now) {
        id = UUID()
        self.serverID = serverID
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = category
        self.paidBy = paidBy
        self.splitMode = splitMode
        self.occurredOn = occurredOn
        self.note = note
        self.cardID = cardID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decodeIfPresent(Int.self, forKey: .serverID)
        amountMinor = try container.decode(Int64.self, forKey: .amountMinor)
        currency = try container.decode(String.self, forKey: .currency)
        category = try container.decode(ExpenseCategory.self, forKey: .category)
        paidBy = try container.decodeIfPresent(ExpensePaidBy.self, forKey: .paidBy)
        splitMode = try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitMode)
        occurredOn = try container.decode(String.self, forKey: .occurredOn)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        cardID = try container.decodeIfPresent(Int.self, forKey: .cardID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        id = try container.decodeIfPresent(UUID.self, forKey: .localID) ?? UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let serverID { try container.encode(serverID, forKey: .serverID) }
        try container.encode(id, forKey: .localID)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(currency, forKey: .currency)
        try container.encode(category, forKey: .category)
        try container.encode(paidBy, forKey: .paidBy)
        try container.encode(splitMode, forKey: .splitMode)
        try container.encode(occurredOn, forKey: .occurredOn)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(cardID, forKey: .cardID)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct TripDaySnapshot: Codable, Sendable, Equatable, Identifiable {
    /// The UUID keeps locally-created, not-yet-synced days uniquely identifiable in SwiftUI.
    let id: UUID
    var serverID: Int?
    var date: String
    var position: Int
    var updatedAt: Date
    var cards: [TravelCardSnapshot]

    enum CodingKeys: String, CodingKey { case serverID = "id", date, position, updatedAt, cards }

    init(serverID: Int? = nil, date: String, position: Int, updatedAt: Date = .now, cards: [TravelCardSnapshot] = []) {
        self.id = UUID()
        self.serverID = serverID
        self.date = date
        self.position = position
        self.updatedAt = updatedAt
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decodeIfPresent(Int.self, forKey: .serverID)
        date = try container.decode(String.self, forKey: .date)
        position = try container.decode(Int.self, forKey: .position)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        cards = try container.decodeIfPresent([TravelCardSnapshot].self, forKey: .cards) ?? []
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let serverID { try container.encode(serverID, forKey: .serverID) }
        try container.encode(date, forKey: .date)
        try container.encode(position, forKey: .position)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(cards, forKey: .cards)
    }
}

struct PlaceSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var placeId: String?
    /// Optional so snapshots cached before cityCode was introduced still decode.
    var cityCode: String?
    /// POI 营业时间；没有可靠数据时保持为空，页面不展示该行。
    var businessHours: String? = nil
    var updatedAt: Date
}

struct TravelCardSnapshot: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case flight, hotel, activity

        var id: String { rawValue }
        var title: String {
            switch self {
            case .flight: String(localized: "kind.flight")
            case .hotel: String(localized: "kind.hotel")
            case .activity: String(localized: "kind.activity")
            }
        }
        var systemImage: String {
            switch self {
            case .flight: "airplane"
            case .hotel: "bed.double"
            case .activity: "mappin.and.ellipse"
            }
        }
    }

    /// Local identity gives an optimistic card a stable SwiftUI key before it has a server ID.
    let id: UUID
    var serverID: Int?
    var dayID: Int
    var kind: Kind
    var title: String
    var startAt: Date
    var endAt: Date?
    var place: PlaceSnapshot?
    var bookingCode: String?
    var url: String?
    /// AI-authored or user-authored short introduction shown above notes.
    var description: String?
    /// Flight-only structured airports (e.g. "HND" -> "KIX").
    var fromAirport: String?
    var toAirport: String?
    /// Estimated price in the trip currency's minor units; nil when the card
    /// has none. The UI renders at most one of estimated/actual price.
    var priceMinor: Int64?
    /// Actual (paid) price in minor units; takes display precedence over the
    /// estimated price when present.
    var actualPriceMinor: Int64?
    /// Admission ticket price in minor units, shown separately from the
    /// estimated/actual price.
    var ticketPriceMinor: Int64?
    /// Planned stay length in whole minutes.
    var stayDurationMinutes: Int?
    /// Ordered short visitor tips.
    var tips: [String]?
    /// Ordered server-hosted image paths for the card detail swiper. Older
    /// snapshots encoded a single `imageUrl`, which is folded in on decode.
    var images: [String]?
    /// Server-owned final image confidence (0...100). The client displays it
    /// for diagnostics only and never derives the large-card decision itself.
    var imageScore: Int
    /// Explicit backend decision for the immersive large-image list card.
    var showLargeImage: Bool
    var notes: String?
    var position: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case serverID = "id", dayID = "dayId", kind, title, startAt, endAt, place, bookingCode, url
        case description, fromAirport = "fromAirport", toAirport = "toAirport", priceMinor
        case actualPriceMinor, ticketPriceMinor, stayDurationMinutes, tips
        case images, legacyImageURL = "imageUrl", imageScore, showLargeImage, notes, position, updatedAt
    }

    init(
        serverID: Int? = nil,
        dayID: Int,
        kind: Kind,
        title: String,
        startAt: Date,
        endAt: Date? = nil,
        place: PlaceSnapshot? = nil,
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
        imageScore: Int = 0,
        showLargeImage: Bool = false,
        notes: String? = nil,
        position: Int = 0,
        updatedAt: Date = .now
    ) {
        id = UUID()
        self.serverID = serverID
        self.dayID = dayID
        self.kind = kind
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.place = place
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
        self.imageScore = max(0, min(100, imageScore))
        self.showLargeImage = showLargeImage && images?.isEmpty == false
        self.notes = notes
        self.position = position
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decodeIfPresent(Int.self, forKey: .serverID)
        dayID = try container.decode(Int.self, forKey: .dayID)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        startAt = try container.decode(Date.self, forKey: .startAt)
        endAt = try container.decodeIfPresent(Date.self, forKey: .endAt)
        place = try container.decodeIfPresent(PlaceSnapshot.self, forKey: .place)
        bookingCode = try container.decodeIfPresent(String.self, forKey: .bookingCode)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        fromAirport = try container.decodeIfPresent(String.self, forKey: .fromAirport)
        toAirport = try container.decodeIfPresent(String.self, forKey: .toAirport)
        priceMinor = try container.decodeIfPresent(Int64.self, forKey: .priceMinor)
        actualPriceMinor = try container.decodeIfPresent(Int64.self, forKey: .actualPriceMinor)
        ticketPriceMinor = try container.decodeIfPresent(Int64.self, forKey: .ticketPriceMinor)
        stayDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .stayDurationMinutes)
        let decodedTips = try container.decodeIfPresent([String].self, forKey: .tips) ?? []
        tips = decodedTips.isEmpty ? nil : decodedTips
        var decodedImages = try container.decodeIfPresent([String].self, forKey: .images) ?? []
        if decodedImages.isEmpty, let legacy = try container.decodeIfPresent(String.self, forKey: .legacyImageURL) {
            decodedImages = [legacy]
        }
        images = decodedImages.isEmpty ? nil : decodedImages
        imageScore = max(0, min(100, try container.decodeIfPresent(Int.self, forKey: .imageScore) ?? 0))
        showLargeImage = (try container.decodeIfPresent(Bool.self, forKey: .showLargeImage) ?? false)
            && !decodedImages.isEmpty
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        position = try container.decode(Int.self, forKey: .position)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let serverID { try container.encode(serverID, forKey: .serverID) }
        try container.encode(dayID, forKey: .dayID)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(startAt, forKey: .startAt)
        try container.encodeIfPresent(endAt, forKey: .endAt)
        try container.encodeIfPresent(place, forKey: .place)
        try container.encodeIfPresent(bookingCode, forKey: .bookingCode)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(fromAirport, forKey: .fromAirport)
        try container.encodeIfPresent(toAirport, forKey: .toAirport)
        try container.encodeIfPresent(priceMinor, forKey: .priceMinor)
        try container.encodeIfPresent(actualPriceMinor, forKey: .actualPriceMinor)
        try container.encodeIfPresent(ticketPriceMinor, forKey: .ticketPriceMinor)
        try container.encodeIfPresent(stayDurationMinutes, forKey: .stayDurationMinutes)
        try container.encodeIfPresent(tips, forKey: .tips)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encode(imageScore, forKey: .imageScore)
        try container.encode(showLargeImage, forKey: .showLargeImage)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(position, forKey: .position)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

@Model
final class SharedTripMirror {
    @Attribute(.unique) var tripID: Int
    var encodedSnapshot: Data
    var tripVersion: Int
    var updatedAt: Date

    init(snapshot: SharedTripSnapshot) throws {
        tripID = snapshot.id
        encodedSnapshot = try JSONEncoder.sharedTrip.encode(snapshot)
        tripVersion = snapshot.version
        updatedAt = snapshot.updatedAt
    }

    func snapshot() throws -> SharedTripSnapshot {
        try JSONDecoder.sharedTrip.decode(SharedTripSnapshot.self, from: encodedSnapshot)
    }

    func replace(with snapshot: SharedTripSnapshot) throws {
        encodedSnapshot = try JSONEncoder.sharedTrip.encode(snapshot)
        tripVersion = snapshot.version
        updatedAt = snapshot.updatedAt
    }
}

@Model
final class PendingOperation {
    @Attribute(.unique) var idempotencyKey: UUID
    var method: String
    var path: String
    var tripID: Int
    var body: Data
    var baseVersion: Int
    var createdAt: Date
    var retryCount: Int
    /// A 4xx validation failure is visible to the user and never retried in
    /// the background. The original operation remains inspectable locally.
    var terminalError: String?
    /// Links an optimistic resource to its queued create operation until it receives a server ID.
    var clientEntityID: UUID?

    init(method: String, path: String, tripID: Int, body: Data, baseVersion: Int, idempotencyKey: UUID = UUID(), clientEntityID: UUID? = nil) {
        self.idempotencyKey = idempotencyKey
        self.method = method
        self.path = path
        self.tripID = tripID
        self.body = body
        self.baseVersion = baseVersion
        createdAt = .now
        retryCount = 0
        terminalError = nil
        self.clientEntityID = clientEntityID
    }

    var payload: PendingOperationPayload {
        PendingOperationPayload(
            method: method,
            path: path,
            tripID: tripID,
            body: body,
            baseVersion: baseVersion,
            idempotencyKey: idempotencyKey
        )
    }
}

/// Holds only selected, structured cards after the user confirms an AI draft.
/// It contains no source text and is deleted as soon as its ordinary card write
/// has been added to the normal idempotent synchronization queue.
@Model
final class ConfirmedAIDraftCard {
    @Attribute(.unique) var localID: UUID
    var date: String
    var kind: String
    var title: String
    var time: String?
    /// Legacy free-text place; retained for migration safety and no longer written.
    var place: String?
/// JSON-encoded `AIChatPlace` proposed by AI; resolved through Apple MapKit
/// only when the user imports the selected card.
var placeData: Data?
var notes: String?
/// JSON-encoded `AICardExtras` (description, estimated price, flight details)
/// carried through the offline queue into the final card write.
var extraData: Data?
var createdAt: Date

init(localID: UUID, date: String, kind: String, title: String, time: String?, placeData: Data?, notes: String?, extraData: Data? = nil) {
self.localID = localID
self.date = date
self.kind = kind
self.title = title
self.time = time
self.place = nil
self.placeData = placeData
self.notes = notes
self.extraData = extraData
createdAt = .now
}

}

struct PendingOperationPayload: Sendable {
    let method: String
    let path: String
    let tripID: Int
    let body: Data
    let baseVersion: Int
    let idempotencyKey: UUID
}

extension JSONEncoder {
    static let sharedTrip: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let sharedTrip: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
