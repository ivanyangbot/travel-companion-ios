import SwiftData
import Foundation
import XCTest
@testable import TravelCompanion

final class AITests: XCTestCase {
    func testDraftDecodesAsSelectedEditableCards() throws {
        let data = Data("""
        {"data":{"days":[{"date":"2026-10-01","cards":[{"kind":"activity","title":"故宫","date":"2026-10-01","time":"09:00","place":{"name":"故宫博物院","address":"北京","latitude":39.9163,"longitude":116.3972,"placeId":"ChIJg","cityCode":null},"notes":null}]}]}}
        """.utf8)

        var draft = try JSONDecoder().decode(APIEnvelope<AIItineraryDraft>.self, from: data).data
        XCTAssertEqual(draft.selectedCards.count, 1)
        draft.days[0].cards[0].isSelected = false
        XCTAssertTrue(draft.selectedCards.isEmpty)
    }

    func testItineraryChatResultDecodesBothLegacyStringAndNormalizedObjectPlace() throws {
        let decoder = JSONDecoder()
        let legacy = Data("""
        {"data":{"reply":"已安排故宫。","cards":[{"kind":"activity","title":"故宫游览","date":"2026-09-22","time":"09:00","place":"故宫博物院","notes":null}]}}
        """.utf8)
        let normalized = Data("""
        {"data":{"reply":"已安排故宫。","cards":[{"kind":"activity","title":"故宫游览","date":"2026-09-22","time":"09:00","place":{"name":"故宫博物院","address":null,"latitude":null,"longitude":null,"placeId":null,"cityCode":null},"notes":null}]}}
        """.utf8)

        let legacyPlace = try decoder.decode(APIEnvelope<AIItineraryChatResult>.self, from: legacy).data.cards[0].place
        let normalizedPlace = try decoder.decode(APIEnvelope<AIItineraryChatResult>.self, from: normalized).data.cards[0].place

        XCTAssertEqual(legacyPlace?.name, "故宫博物院")
        XCTAssertEqual(normalizedPlace?.name, "故宫博物院")
    }

    func testItineraryChatRequestEncodesTripDestinationForPlaceValidation() throws {
        let request = AIItineraryChatRequest(
            messages: [.init(role: "user", content: "安排一天行程")],
            startDate: "2026-09-22",
            days: 1,
            destination: "北京",
            preferences: nil,
            images: nil,
            existingItinerary: nil
        )

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(body?["destination"] as? String, "北京")
    }

    func testItineraryChatMapValidationNormalizesResolvedPlacesAndDisablesUnknownCards() async {
        let known = AIItineraryDraft.Card(
            kind: .activity,
            title: "故宫游览",
            date: "2026-09-22",
            time: "09:00",
            place: AIChatPlace(name: "故宫", address: nil, latitude: nil, longitude: nil, placeId: nil, cityCode: nil),
            notes: nil
        )
        let unknown = AIItineraryDraft.Card(
            kind: .hotel,
            title: "不存在的酒店",
            date: "2026-09-22",
            time: "15:00",
            place: AIChatPlace(name: "虚构地点", address: nil, latitude: nil, longitude: nil, placeId: nil, cityCode: nil),
            notes: "请确认"
        )
        let validated = await AppleMapService.validateItineraryChatCards([known, unknown], destination: "北京") { query, city in
            XCTAssertEqual(city, "北京")
            guard query == "故宫" else { return [] }
            return [.init(id: "known", name: "故宫博物院", address: "北京市东城区", latitude: 39.9163, longitude: 116.3972, placeId: "apple-known")]
        }

        XCTAssertEqual(validated[0].place?.name, "故宫博物院")
        XCTAssertEqual(validated[0].place?.latitude, 39.9163)
        XCTAssertTrue(validated[0].isSelected)
        XCTAssertNil(validated[1].place)
        XCTAssertFalse(validated[1].isSelected)
        XCTAssertTrue(validated[1].notes?.contains(AppleMapService.unverifiedPlaceNote) == true)
    }

    func testItineraryChatMapValidationRejectsAnUnrelatedFirstPOICandidate() async {
        let card = AIItineraryDraft.Card(
            kind: .hotel,
            title: "外南梦酒店",
            date: "2026-09-22",
            time: "15:00",
            place: AIChatPlace(name: "外南梦蒙黎提卡酒店", address: nil, latitude: nil, longitude: nil, placeId: nil, cityCode: nil),
            notes: nil
        )
        let unrelated = PlaceSearchResult(id: "wrong", name: "北京君庭酒店", address: "北京市", latitude: 39.9, longitude: 116.4, placeId: nil)
        let validated = await AppleMapService.validateItineraryChatCards([card], destination: "北京") { _, _ in [unrelated] }

        XCTAssertNil(validated[0].place)
        XCTAssertFalse(validated[0].isSelected)
        XCTAssertTrue(validated[0].notes?.contains(AppleMapService.unverifiedPlaceNote) == true)
    }

    func testSemanticPlaceMatchRequiresOverlappingPlaceNames() {
        let forbidden = PlaceSearchResult(id: "wrong", name: "北京君庭酒店", address: "北京市", latitude: 39.9, longitude: 116.4, placeId: nil)
        let acceptable = PlaceSearchResult(id: "right", name: "故宫博物院", address: "北京市", latitude: 39.9, longitude: 116.4, placeId: nil)

        XCTAssertFalse(AppleMapService.isSemanticPlaceMatch(query: "外南梦蒙黎提卡酒店", candidate: forbidden))
        XCTAssertTrue(AppleMapService.isSemanticPlaceMatch(query: "故宫", candidate: acceptable))
    }

    func testDraftRequiresSelectedCardsWithinTripDatesAndValidTime() {
        let draft = AIItineraryDraft(days: [.init(date: "2026-10-01", cards: [
            .init(kind: .activity, title: "故宫", date: "2026-10-04", time: "9:00", place: nil, notes: nil),
        ])])

        XCTAssertEqual(draft.validationMessage(startDate: "2026-10-01", days: 2), "所选卡片标题需为 1–160 个字符，且日期需在旅行范围内。")
        var timeDraft = draft
        timeDraft.days[0].cards[0].date = "2026-10-01"
        XCTAssertEqual(timeDraft.validationMessage(startDate: "2026-10-01", days: 2), "时间请使用 HH:mm 格式。")
    }

    @MainActor
    func testConfirmedDraftStorageContainsStructuredCardsNotSourceText() throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let card = AIItineraryDraft.Card(kind: .hotel, title: "浅草酒店", date: "2026-10-01", time: nil, place: AIChatPlace(name: "浅草", address: nil, latitude: 35.71, longitude: 139.79, placeId: nil, cityCode: nil), notes: "入住")

        try repository.queueConfirmedAIDraftCards([card])
        let saved = try XCTUnwrap(repository.confirmedAIDraftCards().first)
        XCTAssertEqual(saved.title, "浅草酒店")
        XCTAssertEqual(saved.date, "2026-10-01")
        XCTAssertNil(saved.time)
    }

    @MainActor
    func testOfflineConfirmationQueuesNormalCardWriteWithExistingContract() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let day = TripDaySnapshot(serverID: 17, date: "2026-10-01", position: 0)
        let snapshot = SharedTripSnapshot(id: 1, destination: "东京", startDate: "2026-10-01", endDate: "2026-10-02", currency: "CNY", version: 3, updatedAt: .now, days: [day])
        try repository.save(snapshot)
        let engine = SyncEngine(repository: repository, apiClient: APIClient(baseURL: nil))
        await engine.bootstrap()
        let draft = AIItineraryDraft(days: [.init(date: "2026-10-01", cards: [
            .init(kind: .activity, title: "故宫", date: "2026-10-01", time: "09:00", place: AIChatPlace(name: "故宫", address: "北京", latitude: 39.916, longitude: 116.397, placeId: "ChIJg", cityCode: nil), notes: nil),
        ])])

        try await engine.importAIDraft(draft)

        let operation = try XCTUnwrap(repository.pendingOperations().first)
        XCTAssertEqual(operation.method, "POST")
        XCTAssertEqual(operation.path, "/v1/cards")
        XCTAssertEqual(operation.baseVersion, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: operation.body) as? [String: Any])
        XCTAssertEqual(body["dayId"] as? Int, 17)
        XCTAssertEqual(body["title"] as? String, "故宫")
        // The AI-resolved place must carry real coordinates into the card write.
        let place = try XCTUnwrap(body["place"] as? [String: Any])
        XCTAssertEqual(place["name"] as? String, "故宫")
        XCTAssertEqual(place["latitude"] as? Double, 39.916)
        XCTAssertEqual(place["longitude"] as? Double, 116.397)
        XCTAssertEqual(try XCTUnwrap(repository.confirmedAIDraftCards().first).localID, draft.days[0].cards[0].id)
    }

    func testEditedDraftBoundsBlockConfirmationUntilUserFixesThem() {
        let card = AIItineraryDraft.Card(
            kind: .activity, title: String(repeating: "x", count: 161), date: "2026-10-01",
            time: "09:00", place: AIChatPlace(name: String(repeating: "p", count: 161), address: nil, latitude: 0, longitude: 0, placeId: nil, cityCode: nil), notes: String(repeating: "n", count: 2_001)
        )
        var draft = AIItineraryDraft(days: [.init(date: "2026-10-01", cards: [card])])

        XCTAssertEqual(draft.validationMessage(startDate: "2026-10-01", days: 1), "所选卡片标题需为 1–160 个字符，且日期需在旅行范围内。")
        draft.days[0].cards[0].title = "有效标题"
        XCTAssertEqual(draft.validationMessage(startDate: "2026-10-01", days: 1), "地点名称最多 160 个字符。")
        draft.days[0].cards[0].place = AIChatPlace(name: "有效地点", address: nil, latitude: 0, longitude: 0, placeId: nil, cityCode: nil)
        XCTAssertEqual(draft.validationMessage(startDate: "2026-10-01", days: 1), "备注最多 2000 个字符。")
    }

    @MainActor
    func testCancellingBeforeConfirmationCreatesNoLocalWrite() throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        // A sheet cancel intentionally never calls importAIDraft / repository queue methods.
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
        XCTAssertTrue(try repository.confirmedAIDraftCards().isEmpty)
    }

    func testQueuedOperationRetainsIdempotencyAndExpectedVersionAcrossRetry() async throws {
        APIClientProtocolStub.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientProtocolStub.self]
        let client = APIClient(baseURL: try XCTUnwrap(URL(string: "https://api.example.test")), session: URLSession(configuration: configuration))
        let operation = PendingOperationPayload(
            method: "POST", path: "/v1/cards", tripID: 1, body: Data("{}".utf8), baseVersion: 7, idempotencyKey: UUID()
        )

        _ = try await client.send(operation, tripID: 1)
        _ = try await client.send(operation, tripID: 1)

        XCTAssertEqual(APIClientProtocolStub.requests.count, 2)
        XCTAssertEqual(APIClientProtocolStub.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }, [operation.idempotencyKey.uuidString.lowercased(), operation.idempotencyKey.uuidString.lowercased()])
        XCTAssertEqual(APIClientProtocolStub.requests.map { $0.value(forHTTPHeaderField: "X-Expected-Trip-Version") }, ["7", "7"])
        XCTAssertEqual(APIClientProtocolStub.requests.map { $0.url?.path }, ["/v1/cards", "/v1/cards"])
    }

    @MainActor
    func testPermanentFailureStopsBackgroundRetryAndRetainsConfirmedDraft() throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let card = AIItineraryDraft.Card(kind: .activity, title: "故宫", date: "2026-10-01", time: "09:00", place: nil, notes: nil)
        try repository.queueConfirmedAIDraftCards([card])
        let operation = try repository.enqueue(method: "POST", path: "/v1/cards", tripID: 1, body: Data("{}".utf8), baseVersion: 1, clientEntityID: card.id)

        try repository.markTerminal(operation, message: "日期已被删除")

        XCTAssertTrue(try repository.pendingOperations().isEmpty)
        XCTAssertEqual(try XCTUnwrap(repository.confirmedAIDraftCards().first).localID, card.id)
    }
}

private final class APIClientProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"meta\":{\"tripVersion\":8,\"operationId\":null,\"conflict\":false,\"serverUpdatedAt\":\"2026-10-01T00:00:00Z\"}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
