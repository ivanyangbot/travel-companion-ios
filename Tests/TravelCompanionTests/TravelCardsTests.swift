import Foundation
import SwiftData
import XCTest
@testable import TravelCompanion

final class TravelCardsTests: XCTestCase {
    @MainActor
    func testOnlyPublicHTTPSURLsAreAccepted() {
        XCTAssertEqual(ExternalLinkHandler.validatedHTTPSURL("https://example.com/share")?.host, "example.com")
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("http://example.com"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https:///missing-host"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("not a url"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://user:pass@example.com"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://localhost"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://127.0.0.1"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://10.1.2.3"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://169.254.1.1"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[::1]"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[fe80::1]"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[fc00::1]"))
    }

    func testCardKindsHaveExplicitTextAndSymbols() {
        XCTAssertEqual(TravelCardSnapshot.Kind.flight.title, "机票")
        XCTAssertEqual(TravelCardSnapshot.Kind.hotel.systemImage, "bed.double")
        XCTAssertEqual(TravelCardSnapshot.Kind.activity.title, "活动")
    }

    func testCardPatchEncodesExplicitPlaceClearOnly() throws {
        let request = CardRequest(position: 1, fieldsToClear: ["place"])
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["position"] as? Int, 1)
        XCTAssertTrue(object["place"] is NSNull)
        XCTAssertNil(object["title"])
    }

    func testCardPatchEncodesImagesValueAndExplicitClear() throws {
        let withValue = CardRequest(images: ["/v1/files/abc.jpg"])
        let withObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withValue)) as? [String: Any])
        XCTAssertEqual(withObject["images"] as? [String], ["/v1/files/abc.jpg"])

        let cleared = CardRequest(fieldsToClear: ["images"])
        let clearedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertTrue(clearedObject["images"] is NSNull)
    }

    func testCardSnapshotDecodesImagesAndFoldsLegacyImageURL() throws {
        UserDefaults.standard.set("https://api.example.com", forKey: AppConfiguration.apiBaseURLKey)
        defer { UserDefaults.standard.removeObject(forKey: AppConfiguration.apiBaseURLKey) }

        let json = """
        {"id":7,"dayId":1,"kind":"activity","title":"西湖","startAt":"2026-10-01T09:00:00Z",
         "imageUrl":"/v1/files/abc.jpg","position":0,"updatedAt":"2026-10-01T08:00:00Z"}
        """.data(using: .utf8)!
        let card = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: json)
        XCTAssertEqual(card.images, ["/v1/files/abc.jpg"])
        XCTAssertEqual(CardImageURL.resolve(card.images?.first)?.absoluteString, "https://api.example.com/v1/files/abc.jpg")
        // An absolute URL is returned unchanged.
        XCTAssertEqual(CardImageURL.resolve("https://cdn.example.com/x.png")?.absoluteString, "https://cdn.example.com/x.png")
        XCTAssertNil(CardImageURL.resolve(nil))
    }

    func testCardPriceFormatsMinorUnitsByCurrency() {
        XCTAssertEqual(CardPrice.format(minor: 6000, currency: "CNY")?.contains("60"), true)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "CNY"), 6000)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "JPY"), 60)
        XCTAssertEqual(CardPrice.format(minor: 600, currency: "JPY")?.contains("600"), true)
        XCTAssertNil(CardPrice.minorUnits(from: "abc", currency: "CNY"))
        XCTAssertNil(CardPrice.minorUnits(from: "", currency: "CNY"))
    }

    @MainActor
    func testSignedOutUserCanCreateAndFullyEditLocalTrips() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )

        await engine.bootstrap()
        XCTAssertEqual(engine.status, .localOnly)
        XCTAssertNotNil(engine.trip)
        XCTAssertEqual(engine.trips.count, 1)

        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let end = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        await engine.saveSetup(destination: "杭州", startDate: start, endDate: end, currency: "CNY")
        XCTAssertEqual(engine.trip?.destination, "杭州")

        await engine.addDay(start)
        let day = try XCTUnwrap(engine.trip?.days.first)
        XCTAssertNil(day.serverID)

        await engine.addCard(
            to: day,
            request: CardRequest(kind: .activity, title: "西湖", startAt: "2026-10-01T09:00:00Z", notes: "本地")
        )
        var card = try XCTUnwrap(engine.trip?.days.first?.cards.first)
        XCTAssertNil(card.serverID)
        XCTAssertEqual(card.title, "西湖")

        await engine.updateCard(card, request: CardRequest(title: "西湖漫步", notes: "已编辑"))
        card = try XCTUnwrap(engine.trip?.days.first?.cards.first)
        XCTAssertEqual(card.title, "西湖漫步")

        await engine.deleteCard(card)
        XCTAssertTrue(engine.trip?.days.first?.cards.isEmpty == true)
        await engine.deleteDay(try XCTUnwrap(engine.trip?.days.first))
        XCTAssertTrue(engine.trip?.days.isEmpty == true)

        await engine.createTrip(destination: "上海", startDate: start, endDate: end, currency: "CNY")
        XCTAssertEqual(engine.trips.count, 2)
        XCTAssertEqual(engine.trip?.destination, "上海")
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
    }

    @MainActor
    func testSignedOutBootstrapHidesAccountBackedTripsFromEditableLocalMode() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        try repository.save(SharedTripSnapshot(
            id: 42,
            destination: "云端行程",
            startDate: "2026-10-01",
            endDate: "2026-10-02",
            currency: "CNY",
            version: 7,
            updatedAt: .now,
            days: []
        ))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )

        await engine.bootstrap()

        XCTAssertEqual(engine.status, .localOnly)
        XCTAssertNotNil(engine.trip)
        XCTAssertTrue(try XCTUnwrap(engine.trip?.id) < 0)
        XCTAssertTrue(engine.trips.allSatisfy { $0.id < 0 })
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == 42 })
    }

    @MainActor
    func testFirstLoginImportsLocalSharedDataAndLeavesWalletOnDevice() async throws {
        FirstLoginMigrationURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: sessionConfiguration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self, LocalWalletItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let repository = SharedTripRepository(modelContext: context)
        let card = TravelCardSnapshot(
            serverID: 20,
            dayID: 10,
            kind: .activity,
            title: "西湖",
            startAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")),
            place: PlaceSnapshot(
                id: 30,
                name: "西湖风景名胜区",
                address: "杭州",
                latitude: 30.25,
                longitude: 120.15,
                placeId: "old-place",
                cityCode: "0571",
                updatedAt: .now
            ),
            notes: "本地卡片",
            position: 0
        )
        let day = TripDaySnapshot(serverID: 10, date: "2026-10-01", position: 0, cards: [card])
        let expense = ExpenseSnapshot(
            serverID: 40,
            amountMinor: 12_500,
            currency: "CNY",
            category: .tickets,
            occurredOn: "2026-10-01",
            note: "本地支出",
            cardID: 20
        )
        let localTrip = SharedTripSnapshot(
            id: -1,
            destination: "杭州",
            startDate: "2026-10-01",
            endDate: "2026-10-02",
            currency: "CNY",
            version: 7,
            updatedAt: .now,
            days: [day],
            expenses: [expense]
        )
        try repository.save(localTrip)
        try repository.enqueue(method: "PATCH", path: "/v1/trip", tripID: -1, body: Data("{}".utf8), baseVersion: 7)

        let wallet = LocalWalletItem(label: "只留本地", encryptedSecret: Data("wallet-ciphertext".utf8))
        context.insert(wallet)
        try context.save()

        let suiteName = "FirstLoginMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: LocalTripMigrationStore(defaults: defaults),
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertEqual(engine.trip?.id, 42)
        XCTAssertEqual(engine.trip?.days.first?.cards.first?.title, "西湖")
        XCTAssertEqual(engine.trip?.expenses.first?.amountMinor, 12_500)
        XCTAssertEqual(engine.trip?.expenses.first?.cardID, 201)
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalWalletItem>()).first?.encryptedSecret, wallet.encryptedSecret)
        XCTAssertEqual(
            FirstLoginMigrationURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /v1/trips", "POST /v1/trips", "GET /v1/trip",
                "POST /v1/days", "GET /v1/trip", "POST /v1/cards",
                "GET /v1/trip", "POST /v1/expenses", "GET /v1/trip",
                "GET /v1/trips", "GET /v1/trip",
            ]
        )
        let outboundBodies = FirstLoginMigrationURLProtocol.requests.compactMap(\.httpBody)
        XCTAssertFalse(outboundBodies.contains { String(decoding: $0, as: UTF8.self).contains("wallet-ciphertext") })
    }

    @MainActor
    func testFirstLoginDoesNotMigratePositiveIDAccountCacheOrLegacyPendingState() async throws {
        FirstLoginMigrationURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let positiveAccountCache = SharedTripSnapshot(
            id: 99,
            destination: "其他账号的缓存",
            startDate: "2026-11-01",
            endDate: "2026-11-02",
            currency: "CNY",
            version: 4,
            updatedAt: .now,
            days: []
        )
        try repository.save(positiveAccountCache)
        let suiteName = "PositiveAccountCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrationStore = LocalTripMigrationStore(defaults: defaults)
        try migrationStore.save(PendingLocalTripMigration(source: positiveAccountCache))
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: migrationStore,
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertEqual(FirstLoginMigrationURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["GET /v1/trips"])
        XCTAssertNil(engine.trip)
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == 99 })
        XCTAssertFalse(migrationStore.hasPendingMigration)
    }

    @MainActor
    func testInvalidLegacyPendingCannotKeepMigrationBatchActiveForExistingAccount() async throws {
        FirstLoginMigrationURLProtocol.reset()
        FirstLoginMigrationURLProtocol.tripVersion = 3
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let localTrip = SharedTripSnapshot(
            id: -1, destination: "本地旅程", startDate: "2026-12-01", endDate: "2026-12-02",
            currency: "CNY", version: 0, updatedAt: .now, days: []
        )
        try repository.save(localTrip)
        let legacyAccountCache = SharedTripSnapshot(
            id: 99, destination: "旧账号缓存", startDate: "2026-11-01", endDate: "2026-11-02",
            currency: "CNY", version: 4, updatedAt: .now, days: []
        )
        let suiteName = "LegacyMigrationBatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrationStore = LocalTripMigrationStore(defaults: defaults)
        try migrationStore.save(PendingLocalTripMigration(source: legacyAccountCache))
        migrationStore.beginInitialImportBatch()
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: migrationStore,
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertFalse(FirstLoginMigrationURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(engine.trip?.id, 42)
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == -1 })
        XCTAssertFalse(migrationStore.hasPendingMigration)
        XCTAssertFalse(migrationStore.isInitialImportBatchActive)
    }
}

private final class FirstLoginMigrationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var tripVersion = 0

    static func reset() {
        requests = []
        tripVersion = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let statusCode: Int
        let body: Data

        switch (method, path) {
        case ("GET", "/v1/trips"):
            statusCode = 200
            body = Data((Self.tripVersion == 0 ? "{\"data\":[]}" : Self.tripSummaryListEnvelope).utf8)
        case ("POST", "/v1/trips"):
            statusCode = 200
            body = Data(Self.tripSummaryEnvelope.utf8)
        case ("GET", "/v1/trip") where request.url?.query?.contains("afterVersion=3") == true:
            statusCode = 204
            body = Data()
        case ("GET", "/v1/trip"):
            statusCode = 200
            body = Data(Self.tripEnvelope(version: Self.tripVersion).utf8)
        case ("POST", "/v1/days"):
            Self.tripVersion = 1
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 1).utf8)
        case ("POST", "/v1/cards"):
            Self.tripVersion = 2
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 2).utf8)
        case ("POST", "/v1/expenses"):
            Self.tripVersion = 3
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 3).utf8)
        default:
            statusCode = 404
            body = Data("{\"error\":{\"code\":\"not_found\",\"message\":\"unexpected request\",\"requestId\":\"test\"}}".utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let tripSummaryEnvelope = """
    {"data":{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":3,"updatedAt":"2026-10-01T00:00:00Z","role":"owner","joinedAt":"2026-10-01T00:00:00Z"}}
    """

    private static let tripSummaryListEnvelope = """
    {"data":[{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":3,"updatedAt":"2026-10-01T00:00:00Z","role":"owner","joinedAt":"2026-10-01T00:00:00Z"}]}
    """

    private static func metaEnvelope(version: Int) -> String {
        "{\"meta\":{\"tripVersion\":\(version),\"operationId\":null,\"conflict\":false,\"serverUpdatedAt\":\"2026-10-01T00:00:00Z\"}}"
    }

    private static func tripEnvelope(version: Int) -> String {
        let day = """
        {"id":101,"date":"2026-10-01","position":0,"updatedAt":"2026-10-01T00:00:00Z","cards":\(version >= 2 ? "[\(cardJSON)]" : "[]")}
        """
        let expenses = version >= 3 ? "[\(expenseJSON)]" : "[]"
        let days = version >= 1 ? "[\(day)]" : "[]"
        return """
        {"data":{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":\(version),"updatedAt":"2026-10-01T00:00:00Z","days":\(days),"expenses":\(expenses)}}
        """
    }

    private static let cardJSON = """
    {"id":201,"dayId":101,"kind":"activity","title":"西湖","startAt":"2026-10-01T09:00:00Z","place":{"id":301,"name":"西湖风景名胜区","address":"杭州","latitude":30.25,"longitude":120.15,"placeId":"old-place","cityCode":"0571","updatedAt":"2026-10-01T00:00:00Z"},"notes":"本地卡片","position":0,"updatedAt":"2026-10-01T00:00:00Z"}
    """

    private static let expenseJSON = """
    {"id":401,"amountMinor":12500,"currency":"CNY","category":"tickets","occurredOn":"2026-10-01","note":"本地支出","cardId":201,"updatedAt":"2026-10-01T00:00:00Z"}
    """
}
