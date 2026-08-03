import Foundation
import XCTest
@testable import TravelCompanion

final class AgentV2SessionStoreTests: XCTestCase {
    @MainActor
    func testRestoreRemovesUnverifiedPlaceCandidatesAndTheirChanges() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let failed = candidate(kind: .hotel, status: .failed, place: nil)
        let missingCoordinates = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "只有名称", address: "北京市", latitude: nil, longitude: nil, placeId: nil, cityCode: nil)
        )
        let missingAddress = candidate(
            kind: .hotel,
            status: .verified,
            place: AIChatPlace(name: "无地址酒店", address: nil, latitude: 39.9, longitude: 116.4, placeId: "no-address", cityCode: nil)
        )
        let blankAddress = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "空地址景点", address: "  \n ", latitude: 39.9, longitude: 116.4, placeId: "blank-address", cityCode: nil)
        )
        let verified = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "故宫博物院", address: "北京市东城区", latitude: 39.9163, longitude: 116.3972, placeId: "apple-poi", cityCode: nil)
        )
        let flight = candidate(kind: .flight, status: .notRequired, place: nil)
        let messages = [AgentV2TurnRequest.Message(id: UUID(), role: "user", content: "保留我的输入", createdAt: .now)]
        let attachments = [AgentV2TurnRequest.Attachment(id: UUID(), mediaType: "image/jpeg", dataURI: "data:image/jpeg;base64,AAAA")]
        let changes = [failed, missingCoordinates, missingAddress, blankAddress, verified, flight].map {
            AgentV2Change(id: UUID(), operation: .add, candidateId: $0.id, targetCardId: nil, summary: $0.title, impact: nil)
        }
        let session = AgentV2LocalSession(
            id: UUID(),
            updatedAt: .now,
            preferences: .init(pace: "packed", companions: nil, budget: nil, interests: [], scope: nil),
            messages: messages,
            attachments: attachments,
            draft: AgentV2Draft(candidates: [failed, missingCoordinates, missingAddress, blankAddress, verified, flight], changes: changes),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)

        let store = AgentV2SessionStore(defaults: defaults)

        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [verified.id, flight.id])
        XCTAssertEqual(Set(store.session.draft?.changes.compactMap(\.candidateId) ?? []), Set([verified.id, flight.id]))
        XCTAssertEqual(store.session.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(store.session.messages.map(\.content), messages.map(\.content))
        XCTAssertEqual(store.session.attachments.map(\.id), attachments.map(\.id))

        let persistedData = try XCTUnwrap(defaults.data(forKey: sessionKey))
        let persisted = try decoder.decode(AgentV2LocalSession.self, from: persistedData)
        XCTAssertEqual(persisted.draft?.candidates.map(\.id), [verified.id, flight.id])
    }

    @MainActor
    func testCompletedTurnReplacesOldDraftAndDiscardsPendingCandidateUntilVerifiedPatch() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let old = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "旧地点", address: "旧地址", latitude: 31, longitude: 121, placeId: "old", cityCode: nil)
        )
        let oldChange = AgentV2Change(id: UUID(), operation: .add, candidateId: old.id, targetCardId: nil, summary: "旧变更", impact: nil)
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], scope: nil),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [old], changes: [oldChange]),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)
        let newSummary = AgentV2Summary(text: "新摘要", coveredDates: ["2026-09-23"], pending: [])
        let candidateID = UUID()
        let pending = candidate(id: candidateID, kind: .activity, status: .pending, place: nil)
        let verified = candidate(
            id: candidateID,
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "Kawah Ijen", address: "East Java, Indonesia", latitude: -8.058, longitude: 114.242, placeId: "ijen", cityCode: nil)
        )
        let newChange = AgentV2Change(id: UUID(), operation: .add, candidateId: candidateID, targetCardId: nil, summary: "新增 Kawah Ijen", impact: nil)

        store.beginTurn()
        store.apply(.summary(newSummary))
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [old.id])
        XCTAssertEqual(store.session.summary?.text, "旧摘要")

        store.apply(.candidateUpsert(pending))
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [old.id], "验证中的活动只能存在于内存 staging")

        store.apply(.candidatePatch(id: candidateID, candidate: verified))
        store.apply(.changeSet([newChange]))
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [old.id], "done 前不能污染持久化草稿")
        store.completeTurn()

        XCTAssertEqual(store.session.summary, newSummary)
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [candidateID])
        XCTAssertEqual(store.session.draft?.changes.map(\.id), [newChange.id])
        XCTAssertFalse(store.session.draft?.candidates.contains(where: { $0.id == old.id }) == true)
    }

    @MainActor
    func testCandidatePatchPreservesExistingSelection() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let candidateID = UUID()
        var pending = candidate(id: candidateID, kind: .activity, status: .pending, place: nil)
        pending.selected = true
        var verified = candidate(
            id: candidateID,
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "浅草寺", address: "东京台东区", latitude: 35.7148, longitude: 139.7967, placeId: "asakusa", cityCode: nil)
        )
        verified.selected = false // The server always emits selected=false.

        let store = AgentV2SessionStore(defaults: defaults)
        store.beginTurn()
        store.apply(.candidateUpsert(pending))
        store.apply(.candidatePatch(id: candidateID, candidate: verified))
        store.completeTurn()

        XCTAssertEqual(store.session.draft?.candidates.first?.id, candidateID)
        XCTAssertTrue(store.session.draft?.candidates.first?.selected == true)
    }

    @MainActor
    func testCommitSnapshotKeepsDraftAndSelectedIDsFromSamePublishedState() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let selected = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "浅草寺", address: "东京台东区", latitude: 35.7148, longitude: 139.7967, placeId: "asakusa", cityCode: nil)
        )
        var unselected = candidate(kind: .flight, status: .notRequired, place: nil)
        unselected.selected = false
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], scope: nil),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [selected, unselected], changes: []), summary: nil
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        let snapshot = try XCTUnwrap(store.commitSnapshot())

        XCTAssertEqual(snapshot.draft.candidates.map(\.id), [selected.id, unselected.id])
        XCTAssertEqual(snapshot.selected.map(\.id), [selected.id])
        XCTAssertTrue(Set(snapshot.selected.map(\.id)).isSubset(of: Set(snapshot.draft.candidates.map(\.id))))
    }

    @MainActor
    func testDiscardAfterSummaryAndCandidatePreservesOldDraftAndSummary() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let old = candidate(
            kind: .hotel,
            status: .verified,
            place: AIChatPlace(name: "旧酒店", address: "旧地址", latitude: 31, longitude: 121, placeId: "old-hotel", cityCode: nil)
        )
        let oldSummary = AgentV2Summary(text: "上一轮可用结果", coveredDates: ["2026-09-22"], pending: [])
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], scope: nil),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [old], changes: []), summary: oldSummary
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)
        let incoming = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "新景点", address: "新地址", latitude: 35, longitude: 139, placeId: "new-poi", cityCode: nil)
        )

        store.beginTurn()
        store.apply(.summary(.init(text: "尚未完成的新结果", coveredDates: [], pending: [])))
        store.apply(.candidateUpsert(incoming))
        store.discardTurn()

        XCTAssertEqual(store.session.summary, oldSummary)
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [old.id])
        let persistedData = try XCTUnwrap(defaults.data(forKey: sessionKey))
        let persisted = try decoder.decode(AgentV2LocalSession.self, from: persistedData)
        XCTAssertEqual(persisted.summary, oldSummary)
        XCTAssertEqual(persisted.draft?.candidates.map(\.id), [old.id])
    }

    private let defaultsSuite = "AgentV2SessionStoreTests"
    private let sessionKey = "agent.v2.local.session"

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        return defaults
    }

    private func candidate(
        id: UUID = UUID(),
        kind: TravelCardSnapshot.Kind,
        status: AgentV2Candidate.PlaceStatus,
        place: AIChatPlace?
    ) -> AgentV2Candidate {
        AgentV2Candidate(
            id: id, kind: kind, title: "候选 \(id.uuidString.prefix(4))", date: "2026-09-23", startAt: "09:00", endAt: nil,
            place: place, placeStatus: status, description: nil, notes: nil, url: nil, priceMinor: nil,
            ticketPriceMinor: nil, stayDurationMinutes: nil, tips: [], bookingCode: kind == .flight ? "CA123" : nil,
            fromAirport: kind == .flight ? "PEK" : nil, toAirport: kind == .flight ? "HND" : nil,
            reason: nil, risks: [], missingFields: [], selected: true
        )
    }
}
