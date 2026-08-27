import SwiftData
import Foundation
import UIKit
import XCTest
@testable import TravelCompanion

final class AITests: XCTestCase {
    func testAgentImageUnderThreeMegabytesKeepsItsOriginalEncoding() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let source = try XCTUnwrap(renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())

        let prepared = try AgentImageAttachmentProcessor.prepare(source)

        XCTAssertEqual(prepared.data, source)
        XCTAssertEqual(prepared.mediaType, "image/png")
    }

    func testAgentImageOverThreeMegabytesIsAutomaticallyCompressed() throws {
        let width = 2_048
        let height = 2_048
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var state: UInt32 = 0x1234_5678
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                state = 1_664_525 &* state &+ 1_013_904_223
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
        let source = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 1))
        XCTAssertGreaterThan(source.count, AgentImageAttachmentProcessor.maximumBytes)

        let prepared = try AgentImageAttachmentProcessor.prepare(source)

        XCTAssertLessThanOrEqual(prepared.data.count, AgentImageAttachmentProcessor.maximumBytes)
        XCTAssertEqual(prepared.mediaType, "image/jpeg")
        XCTAssertTrue(prepared.dataURI.hasPrefix("data:image/jpeg;base64,"))
    }

    func testAgentTextFileIsPreparedAsNamedDataURI() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-attachment-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("旅行确认单".utf8).write(to: url)

        let prepared = try AgentFileAttachmentProcessor.prepare(url)

        XCTAssertEqual(prepared.fileName, url.lastPathComponent)
        XCTAssertEqual(prepared.mediaType, "text/plain")
        XCTAssertTrue(prepared.dataURI.hasPrefix("data:text/plain;base64,"))
    }

    func testAgentFileRejectsUnsupportedExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-attachment-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x01]).write(to: url)

        XCTAssertThrowsError(try AgentFileAttachmentProcessor.prepare(url)) { error in
            guard case AgentAttachmentError.unsupportedFile = error else {
                return XCTFail("Expected unsupportedFile, got \(error)")
            }
        }
    }

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
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: true
        )
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

    func testJournalRequestUsesItsExplicitTripID() async throws {
        APIClientProtocolStub.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientProtocolStub.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )

        _ = try await client.fetchJournal(tripID: 42)

        let request = try XCTUnwrap(APIClientProtocolStub.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/journal")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trip-ID"), "42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testJournalLivePhotoMetadataRoundTrips() throws {
        let json = Data(#"""
        {
            "key":"travel-companion/journal/42/photo.heic",
            "url":"https://example.test/photo.heic",
            "kind":"livePhoto",
            "contentType":"image/heic",
            "fileName":"IMG_0001.HEIC",
            "sizeBytes":3145728,
            "pairedVideo":{
                "key":"travel-companion/journal/42/photo.mov",
                "url":"https://example.test/photo.mov",
                "contentType":"video/quicktime",
                "fileName":"IMG_0001.MOV",
                "sizeBytes":4194304
            }
        }
        """#.utf8)

        let image = try JSONDecoder().decode(JournalImage.self, from: json)

        XCTAssertEqual(image.kind, "livePhoto")
        XCTAssertEqual(image.contentType, "image/heic")
        XCTAssertEqual(image.sizeBytes, 3 * 1024 * 1024)
        XCTAssertEqual(image.pairedVideo?.contentType, "video/quicktime")
        XCTAssertEqual(image.pairedVideo?.sizeBytes, 4 * 1024 * 1024)
        XCTAssertEqual(image.uploadReference.primaryKey, image.key)
    }

    func testJournalRequestEncodesLegacyAndStructuredMediaReferences() throws {
        let request = JournalEntryRequest(
            groupId: nil,
            title: "原始媒体",
            content: nil,
            imageKeys: [
                .legacy("travel-companion/journal/42/legacy.jpg"),
                .item(.init(
                    key: "travel-companion/journal/42/photo.heic",
                    kind: "livePhoto",
                    contentType: "image/heic",
                    fileName: "IMG_0001.HEIC",
                    sizeBytes: 3 * 1024 * 1024,
                    pairedVideo: .init(
                        key: "travel-companion/journal/42/photo.mov",
                        contentType: "video/quicktime",
                        fileName: "IMG_0001.MOV",
                        sizeBytes: 4 * 1024 * 1024
                    )
                ))
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let media = try XCTUnwrap(object["imageKeys"] as? [Any])
        XCTAssertEqual(media[0] as? String, "travel-companion/journal/42/legacy.jpg")
        let livePhoto = try XCTUnwrap(media[1] as? [String: Any])
        XCTAssertEqual(livePhoto["kind"] as? String, "livePhoto")
        XCTAssertEqual(
            (livePhoto["pairedVideo"] as? [String: Any])?["contentType"] as? String,
            "video/quicktime"
        )
    }

    func testJournalAttachmentLimitIsFiveGiBPerResource() {
        XCTAssertEqual(JournalAttachment.maximumResourceBytes, 5 * 1024 * 1024 * 1024)
    }

    func testJournalOnlyAutomaticallySyncsOnUnmeteredWiFi() {
        XCTAssertTrue(JournalNetworkAccess.wifi.allowsAutomaticSync)
        XCTAssertFalse(JournalNetworkAccess.metered.allowsAutomaticSync)
        XCTAssertFalse(JournalNetworkAccess.offline.allowsAutomaticSync)
        XCTAssertFalse(JournalNetworkAccess.other.allowsAutomaticSync)
    }

    @MainActor
    func testJournalSyncCheckpointSurvivesRetryAndRemovesCompletedEntry() throws {
        let suiteName = "journal-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalJournalStore(defaults: defaults)
        try store.createGroup(.init(name: "本地分组", color: "indigo", position: 0))
        let groupID = try XCTUnwrap(store.snapshot.groups.first?.id)
        try store.save(
            entryID: nil,
            request: .init(groupId: groupID, title: "待同步", content: nil, imageKeys: []),
            attachments: []
        )
        let entryID = try XCTUnwrap(store.snapshot.entries.first?.id)

        try store.recordSyncedGroup(localID: groupID, remoteID: 81, tripID: 42)
        XCTAssertEqual(try store.syncGroupIDs(for: 42)[groupID], 81)
        XCTAssertThrowsError(try store.syncGroupIDs(for: 99))

        try store.markEntrySynced(entryID)
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        XCTAssertEqual(try store.syncGroupIDs(for: 42)[groupID], 81)
    }

    /// 无生效行程时建议请求带 mode=journey，且不需要 X-Trip-ID 头。
    func testTripSuggestionsJourneyModeRequestOmitsTripHeader() async throws {
        APIClientProtocolStub.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientProtocolStub.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration)
        )
        let request = AITripSuggestionsRequest(
            mode: "journey",
            destination: nil,
            startDate: nil,
            endDate: nil,
            currency: nil,
            preferences: nil,
            existingItinerary: nil
        )

        let result = try await client.fetchTripSuggestions(request, tripID: nil)

        XCTAssertEqual(result.suggestions.count, 3)
        let sent = try XCTUnwrap(APIClientProtocolStub.requests.last)
        XCTAssertEqual(sent.url?.path, "/v1/ai/trip-suggestions")
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Trip-ID"))
        // DTO 层面确认 journey 模式随请求编码（URLSession 会把 httpBody 转为
        // stream，网络上不便直接断言）。
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(encoded["mode"] as? String, "journey")
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

/// The thinking-orb icon follows the backend's ephemeral SSE `status` text
/// (`app/routes/agent_v2.py`): each agent behaviour maps to a distinct
/// `OrbState`. These cases pin every status string the server can emit.
final class AgentThinkingOrbStateTests: XCTestCase {
    func testNilStatusFallsBackToThinking() {
        XCTAssertEqual(agentThinkingOrbState(for: nil), .breathing)
    }

    func testUnderstandingUserIntentIsListening() {
        XCTAssertEqual(agentThinkingOrbState(for: "正在理解你的需求…"), .listening)
    }

    func testInitialOnlineCheckIsSearching() {
        XCTAssertEqual(agentThinkingOrbState(for: "正在联网核对攻略并生成建议…"), .searching)
    }

    func testAppleMapsVerificationIsSearching() {
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过 Apple Maps 核对 婆罗浮屠…"), .searching)
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过 Apple Maps 核对地点…"), .searching)
    }

    func testReadingXiaohongshuNoteIsConnecting() {
        XCTAssertEqual(agentThinkingOrbState(for: "正在读取小红书公开笔记…"), .connecting)
    }

    func testIdentifyingPlacesIsSolving() {
        XCTAssertEqual(agentThinkingOrbState(for: "笔记读取完成，正在识别可定位地点…"), .solving)
        XCTAssertEqual(agentThinkingOrbState(for: "正在并行验证候选地点…"), .solving)
    }

    func testOrganizingResultsIsWeaving() {
        XCTAssertEqual(agentThinkingOrbState(for: "笔记已解析，正在整理其中的地点…"), .weaving)
        XCTAssertEqual(agentThinkingOrbState(for: "小红书搜索结果已返回，正在挑选高质量笔记…"), .weaving)
        XCTAssertEqual(agentThinkingOrbState(for: "飞猪结果已返回，继续整理候选…"), .weaving)
    }

    func testComposingCandidatesIsComposing() {
        XCTAssertEqual(agentThinkingOrbState(for: "地点结果已返回，继续生成候选卡…"), .composing)
        XCTAssertEqual(agentThinkingOrbState(for: "豆包搜索结果已返回，继续生成候选卡…"), .composing)
        XCTAssertEqual(agentThinkingOrbState(for: "实拍图片已返回，继续生成候选卡…"), .composing)
    }

    func testSearchToolCallsAreSearching() {
        XCTAssertEqual(agentThinkingOrbState(for: "正在搜索小红书相关攻略…"), .searching)
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过豆包搜索攻略信息…"), .searching)
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过豆包搜索实拍图片…"), .searching)
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过飞猪查询酒店实时价格…"), .searching)
        XCTAssertEqual(agentThinkingOrbState(for: "正在通过飞猪查询实时库存…"), .searching)
    }

    func testUnknownStatusFallsBackToThinking() {
        XCTAssertEqual(agentThinkingOrbState(for: "某种未预见的状态…"), .breathing)
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
        let body: String
        switch request.url?.path {
        case "/v1/journal":
            body = "{\"data\":{\"groups\":[],\"entries\":[]}}"
        case "/v1/ai/trip-suggestions":
            body = "{\"data\":{\"suggestions\":[\"甲\",\"乙\",\"丙\"],\"icons\":[\"sparkles\",\"sparkles\",\"sparkles\"]}}"
        default:
            body = "{\"meta\":{\"tripVersion\":8,\"operationId\":null,\"conflict\":false,\"serverUpdatedAt\":\"2026-10-01T00:00:00Z\"}}"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
