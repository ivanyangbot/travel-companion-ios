import Foundation
import XCTest
@testable import TravelCompanion

final class AgentV2SessionStoreTests: XCTestCase {
    @MainActor
    func testRestoreKeepsExplicitTextOnlyPlaceAndRemovesUnsafeUnverifiedCandidates() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let failed = candidate(kind: .hotel, status: .failed, place: nil)
        var explicitFailed = candidate(kind: .hotel, status: .failed, place: nil)
        explicitFailed.sourceText = "末見山・日照金山雪山觀景新宿（雪嵩村店）"
        var allowedRecommendation = candidate(kind: .activity, status: .failed, place: nil)
        allowedRecommendation.allowsUnverifiedPlace = true
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
        let changes = [failed, explicitFailed, allowedRecommendation, missingCoordinates, missingAddress, blankAddress, verified, flight].map {
            AgentV2Change(id: UUID(), operation: .add, candidateId: $0.id, targetCardId: nil, summary: $0.title, impact: nil)
        }
        let session = AgentV2LocalSession(
            id: UUID(),
            updatedAt: .now,
            preferences: .init(pace: "packed", companions: nil, budget: nil, interests: []),
            messages: messages,
            attachments: attachments,
            draft: AgentV2Draft(candidates: [failed, explicitFailed, allowedRecommendation, missingCoordinates, missingAddress, blankAddress, verified, flight], changes: changes),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)

        let store = AgentV2SessionStore(defaults: defaults)

        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [explicitFailed.id, allowedRecommendation.id, verified.id, flight.id])
        XCTAssertTrue(store.session.draft?.candidates.first?.isCommitReady == true)
        XCTAssertEqual(Set(store.session.draft?.changes.compactMap(\.candidateId) ?? []), Set([explicitFailed.id, allowedRecommendation.id, verified.id, flight.id]))
        XCTAssertEqual(store.session.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(store.session.messages.map(\.content), messages.map(\.content))
        XCTAssertEqual(store.session.attachments.map(\.id), attachments.map(\.id))

        let persistedData = try XCTUnwrap(defaults.data(forKey: sessionKey))
        let persisted = try decoder.decode(AgentV2LocalSession.self, from: persistedData)
        XCTAssertEqual(persisted.draft?.candidates.map(\.id), [explicitFailed.id, allowedRecommendation.id, verified.id, flight.id])
    }

    @MainActor
    func testCompletedTurnRetiresDraftOnlyViaTargetDraftId() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let old = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "旧地点", address: "旧地址", latitude: 31, longitude: 121, placeId: "old", cityCode: nil)
        )
        let oldChange = AgentV2Change(id: UUID(), operation: .add, candidateId: old.id, targetCardId: nil, targetDraftId: nil, summary: "旧变更", impact: nil)
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
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
        let newChange = AgentV2Change(id: UUID(), operation: .replace, candidateId: candidateID, targetCardId: nil, targetDraftId: old.id, summary: "替换旧地点", impact: nil)

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
        // replace(targetDraftId=old) 退役旧草稿，仅保留新候选。
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [candidateID])
        XCTAssertFalse(store.session.draft?.candidates.contains(where: { $0.id == old.id }) == true)
    }

    @MainActor
    func testCompletedTurnCarriesForwardUntouchedDrafts() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let kept = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "保留景点", address: "地址", latitude: 31, longitude: 121, placeId: "kept", cityCode: nil)
        )
        let keptChange = AgentV2Change(id: UUID(), operation: .add, candidateId: kept.id, targetCardId: nil, targetDraftId: nil, summary: "新增保留景点", impact: nil)
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [kept], changes: [keptChange]),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        let freshID = UUID()
        let fresh = candidate(id: freshID, kind: .flight, status: .notRequired, place: nil)
        let freshChange = AgentV2Change(id: UUID(), operation: .add, candidateId: freshID, targetCardId: nil, targetDraftId: nil, summary: "新增航班", impact: nil)

        store.beginTurn()
        store.apply(.summary(.init(text: "又加了一张", coveredDates: ["2026-09-23"], pending: [])))
        store.apply(.candidateUpsert(fresh))
        store.apply(.changeSet([freshChange]))
        store.completeTurn()

        // 新候选在前，未提及的旧草稿随候选与关联 change 一并延续到下一轮。
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [freshID, kept.id])
        XCTAssertEqual(Set(store.session.draft?.changes.map(\.id) ?? []), Set([freshChange.id, keptChange.id]))
    }

    @MainActor
    func testCompletedTurnRemovesDraftViaTargetDraftId() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let removed = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "删除景点", address: "地址", latitude: 31, longitude: 121, placeId: "rm", cityCode: nil)
        )
        let kept = candidate(
            kind: .hotel,
            status: .verified,
            place: AIChatPlace(name: "保留酒店", address: "地址", latitude: 31, longitude: 121, placeId: "keep", cityCode: nil)
        )
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [removed, kept], changes: [
                AgentV2Change(id: UUID(), operation: .add, candidateId: removed.id, targetCardId: nil, targetDraftId: nil, summary: "新增删除景点", impact: nil),
                AgentV2Change(id: UUID(), operation: .add, candidateId: kept.id, targetCardId: nil, targetDraftId: nil, summary: "新增保留酒店", impact: nil),
            ]),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        store.beginTurn()
        store.apply(.summary(.init(text: "删掉那张", coveredDates: [], pending: [])))
        store.apply(.changeSet([AgentV2Change(id: UUID(), operation: .remove, candidateId: nil, targetCardId: nil, targetDraftId: removed.id, summary: "删除草稿", impact: nil)]))
        store.completeTurn()

        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [kept.id])
        XCTAssertEqual(store.session.draft?.changes.compactMap(\.candidateId), [kept.id])
    }

    @MainActor
    func testPureReplyTurnPreservesPreviousDraft() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let old = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "旧景点", address: "地址", latitude: 31, longitude: 121, placeId: "old", cityCode: nil)
        )
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [old], changes: []),
            summary: AgentV2Summary(text: "旧摘要", coveredDates: [], pending: [])
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        // 一轮只有摘要、没有候选/changes 的纯问答不应当清空未确认草稿。
        store.beginTurn()
        store.apply(.summary(.init(text: "只是回答了一个问题", coveredDates: [], pending: [])))
        store.completeTurn()

        XCTAssertEqual(store.session.summary?.text, "只是回答了一个问题")
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [old.id])
    }

    @MainActor
    func testLastTurnCandidateIDsTrackCurrentTurnForGrouping() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let old = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "旧景点", address: "地址", latitude: 31, longitude: 121, placeId: "old", cityCode: nil)
        )
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [old], changes: []), summary: nil
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)
        let freshID = UUID()

        store.beginTurn()
        store.apply(.candidateUpsert(candidate(id: freshID, kind: .flight, status: .notRequired, place: nil)))
        store.completeTurn()

        // 本轮产出的候选被标记，前几轮遗留的不在集合中，供 UI 分组。
        XCTAssertEqual(store.session.lastTurnCandidateIDs, [freshID])
        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [freshID, old.id])

        store.clearCommittedDraft()
        XCTAssertNil(store.session.lastTurnCandidateIDs)
    }

    @MainActor
    func testCommitSnapshotAllowsPureRemovalCommit() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        var unselected = candidate(kind: .flight, status: .notRequired, place: nil)
        unselected.selected = false
        let removal = AgentV2Change(id: UUID(), operation: .remove, candidateId: nil, targetCardId: 42, targetDraftId: nil, summary: "移除第 1 天重复卡", impact: nil)
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [unselected], changes: [removal]), summary: nil
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        let snapshot = try XCTUnwrap(store.commitSnapshot(), "没有选中候选但存在待移除行程卡时也应允许提交")
        XCTAssertTrue(snapshot.selected.isEmpty)
        XCTAssertEqual(snapshot.draft.changes.map(\.id), [removal.id])
    }

    @MainActor
    func testRemovedDraftChangeStaysVisibleUntilNextTurn() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let removed = candidate(
            kind: .activity,
            status: .verified,
            place: AIChatPlace(name: "删除景点", address: "地址", latitude: 31, longitude: 121, placeId: "rm", cityCode: nil)
        )
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [removed], changes: []), summary: nil
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)
        let removal = AgentV2Change(id: UUID(), operation: .remove, candidateId: nil, targetCardId: nil, targetDraftId: removed.id, summary: "移除该候选", impact: nil)

        store.beginTurn()
        store.apply(.summary(.init(text: "已移除", coveredDates: [], pending: [])))
        store.apply(.changeSet([removal]))
        store.completeTurn()

        // 移除记录保留在变更清单中，向用户解释卡片为何消失。
        XCTAssertTrue(store.session.draft?.candidates.isEmpty == true)
        XCTAssertEqual(store.session.draft?.changes.map(\.id), [removal.id])

        // 下一个产出内容的轮次合并时该记录已应用完毕，不再跨轮累积。
        let freshID = UUID()
        store.beginTurn()
        store.apply(.candidateUpsert(candidate(id: freshID, kind: .flight, status: .notRequired, place: nil)))
        store.apply(.changeSet([AgentV2Change(id: UUID(), operation: .add, candidateId: freshID, targetCardId: nil, targetDraftId: nil, summary: "新增航班", impact: nil)]))
        store.completeTurn()
        XCTAssertEqual(store.session.draft?.changes.map(\.targetDraftId) ?? [], [nil])
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
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
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
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
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

    @MainActor
    func testBatchSelectionUpdatesAllCommitReadyCandidatesTogether() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        var first = candidate(kind: .flight, status: .notRequired, place: nil)
        var second = candidate(kind: .flight, status: .notRequired, place: nil)
        first.selected = false
        second.selected = false
        let session = AgentV2LocalSession(
            id: UUID(), updatedAt: .now,
            preferences: .init(pace: nil, companions: nil, budget: nil, interests: []),
            messages: [], attachments: [],
            draft: AgentV2Draft(candidates: [first, second], changes: []), summary: nil
        )
        defaults.set(try encoder.encode(session), forKey: sessionKey)
        let store = AgentV2SessionStore(defaults: defaults)

        store.setSelected(true, ids: Set([first.id, second.id]))

        XCTAssertEqual(store.session.draft?.candidates.filter(\.selected).map(\.id), [first.id, second.id])
    }

    @MainActor
    func testCompletedTurnPublishesExplicitUnverifiedCandidateAsAddableDraft() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        var pendingPlace = candidate(kind: .activity, status: .failed, place: nil)
        pendingPlace.sourceText = "大經幡"
        pendingPlace.missingFields = ["地图地点待确认"]
        let change = AgentV2Change(
            id: UUID(), operation: .add, candidateId: pendingPlace.id,
            targetCardId: nil, summary: "新增大经幡", impact: nil
        )
        let store = AgentV2SessionStore(defaults: defaults)

        store.beginTurn()
        store.apply(.candidateUpsert(pendingPlace))
        store.apply(.changeSet([change]))
        store.completeTurn()

        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [pendingPlace.id])
        XCTAssertTrue(store.session.draft?.candidates.first?.isCommitReady == true)
        XCTAssertEqual(store.commitSnapshot()?.selected.map(\.id), [pendingPlace.id])
    }

    @MainActor
    func testUserAllowedModelRecommendationIsPersistedAndCommitReady() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        var recommendation = candidate(kind: .activity, status: .failed, place: nil)
        recommendation.sourceText = nil
        recommendation.allowsUnverifiedPlace = true
        recommendation.missingFields = ["地图地点待确认"]
        let store = AgentV2SessionStore(defaults: defaults)

        store.beginTurn()
        store.apply(.candidateUpsert(recommendation))
        store.apply(.changeSet([
            AgentV2Change(id: UUID(), operation: .add, candidateId: recommendation.id, targetCardId: nil, summary: "新增模型推荐", impact: nil)
        ]))
        store.completeTurn()

        XCTAssertEqual(store.session.draft?.candidates.map(\.id), [recommendation.id])
        XCTAssertTrue(store.session.draft?.candidates.first?.isCommitReady == true)
    }

    @MainActor
    func testUnverifiedRecommendationSwitchDefaultsOnAndPersistsUserChoice() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let store = AgentV2SessionStore(defaults: defaults)

        XCTAssertTrue(store.session.preferences.retainsUnverifiedRecommendations)
        store.setAllowUnverifiedRecommendations(false)
        XCTAssertFalse(store.session.preferences.retainsUnverifiedRecommendations)

        let restored = AgentV2SessionStore(defaults: defaults)
        XCTAssertFalse(restored.session.preferences.retainsUnverifiedRecommendations)
    }

    @MainActor
    func testTrimmedHistoryCapsTurnsAndMessageLength() throws {
        let longContent = String(repeating: "长", count: 2_500)
        let messages = (0 ..< 25).map { index in
            AgentV2TurnRequest.Message(
                id: UUID(), role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: index == 24 ? longContent : "消息 \(index)", createdAt: .now
            )
        }

        let trimmed = AgentV2TurnRequest.trimmedHistory(messages)

        XCTAssertEqual(trimmed.count, 20)
        XCTAssertEqual(trimmed.first?.content, "消息 5")
        XCTAssertEqual(trimmed.last?.content.count, 2_000)
        XCTAssertEqual(trimmed.last?.id, messages.last?.id, "裁剪只截断文本，不改变消息身份")
    }

    @MainActor
    func testRunStateRemainsGeneratingUntilSharedTaskFinishes() async throws {
        let state = AgentV2RunState()
        state.prepareForTurn()
        let generationID = state.beginGeneration()
        let task = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(20)) }
        state.attach(task, id: generationID)

        XCTAssertTrue(state.isGenerating)
        XCTAssertEqual(state.status, "正在理解你的需求…")

        await task.value
        state.finishGeneration(id: generationID)
        XCTAssertFalse(state.isGenerating)
        XCTAssertNil(state.status)
    }

    @MainActor
    func testStreamingReplyCoalescesFragmentsAndFlushesBeforeCompletion() async throws {
        let state = AgentV2RunState()
        state.prepareForTurn()

        state.appendStreamingReply("你")
        state.appendStreamingReply("好")
        XCTAssertEqual(state.streamingReply, "", "short SSE bursts should not publish every token")

        state.flushStreamingReply()
        XCTAssertEqual(state.streamingReply, "你好")

        state.appendStreamingReply("，世界")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.streamingReply, "你好，世界")

        state.appendStreamingReply("不应泄漏")
        state.prepareForTurn()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.streamingReply, "", "reset must cancel and discard a pending flush")
    }

    @MainActor
    func testFliggyProgressLifecycleAcrossStartedAndCompleted() async throws {
        let state = AgentV2RunState()
        state.fliggyFadeInterval = 0.05
        state.prepareForTurn()
        XCTAssertNil(state.fliggyProgress)

        state.fliggySearchStarted(try fliggyStart(["searchType": "flight", "origin": "北京"]))
        XCTAssertEqual(state.fliggyProgress?.kind, .flight)
        XCTAssertEqual(state.fliggyProgress?.term, "北京")
        XCTAssertEqual(state.fliggyProgress?.phase, .running)

        // A second start replaces the first chip (paired per tool call).
        state.fliggySearchStarted(try fliggyStart(["searchType": "hotel", "query": "外滩"]))
        XCTAssertEqual(state.fliggyProgress?.kind, .hotel)
        XCTAssertEqual(state.fliggyProgress?.phase, .running)

        // ok=true: keeps the last term, shows count, then fades out.
        state.fliggySearchCompleted(try fliggyCompletion(["searchType": "hotel", "ok": true, "count": 8]))
        XCTAssertEqual(state.fliggyProgress?.kind, .hotel)
        XCTAssertEqual(state.fliggyProgress?.term, "外滩")
        XCTAssertEqual(state.fliggyProgress?.phase, .completed(ok: true, count: 8))

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(state.fliggyProgress, "ok=true chip should fade out after the interval")
    }

    @MainActor
    func testFliggyFailedCompletionPersistsUntilTurnEnds() async throws {
        let state = AgentV2RunState()
        state.fliggyFadeInterval = 0.05
        state.prepareForTurn()
        state.fliggySearchStarted(try fliggyStart(["searchType": "train"]))
        state.fliggySearchCompleted(try fliggyCompletion(["searchType": "train", "ok": false]))

        XCTAssertEqual(state.fliggyProgress?.phase, .completed(ok: false, count: nil))
        // Degradation notice must survive past the fade interval: the model
        // keeps going with other sources, but the user should see why.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.fliggyProgress?.phase, .completed(ok: false, count: nil))

        // Ending the turn clears it.
        let generationID = state.beginGeneration()
        state.finishGeneration(id: generationID)
        XCTAssertNil(state.fliggyProgress)
    }

    @MainActor
    func testFliggySearchKindMapsProgressTitles() {
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "hotel").progressTitle, "正在查询飞猪酒店实时价格")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "flight").progressTitle, "正在查询机票实时价格")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "train").progressTitle, "正在查询火车票实时价格")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "poi").progressTitle, "正在查询景点门票实时价格")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "fast").progressTitle, "正在查询飞猪实时库存")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "unexpected").progressTitle, "正在查询飞猪实时库存")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: "unexpected"), .other)
    }

    @MainActor
    func testTripProposalPublishesOnDoneAndClearsAfterConfirm() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let store = AgentV2SessionStore(defaults: defaults)

        let proposal = AgentV2TripProposal(destination: "云南", startDate: "2026-10-01", endDate: "2026-10-07", currency: "CNY", timeZone: "Asia/Shanghai")

        store.beginTurn()
        store.apply(.tripProposal(proposal))
        // 提案随事务暂存，done（completeTurn）前不发布到会话
        XCTAssertNil(store.session.pendingProposal)
        store.completeTurn()
        XCTAssertEqual(store.session.pendingProposal, proposal)

        // 新一轮未产出提案：保留原有待确认提案
        store.beginTurn()
        store.apply(.summary(AgentV2Summary(text: "继续讨论", coveredDates: [], pending: [])))
        store.completeTurn()
        XCTAssertEqual(store.session.pendingProposal, proposal)

        // 新一轮产出新提案：覆盖旧提案
        let updated = AgentV2TripProposal(destination: "云南", startDate: "2026-11-01", endDate: "2026-11-05", currency: "CNY", timeZone: "Asia/Shanghai")
        store.beginTurn()
        store.apply(.tripProposal(updated))
        store.completeTurn()
        XCTAssertEqual(store.session.pendingProposal, updated)

        // 提案随会话持久化，重启后可恢复；确认创建旅程后清除
        let restored = AgentV2SessionStore(defaults: defaults)
        XCTAssertEqual(restored.session.pendingProposal, updated)
        restored.clearPendingProposal()
        XCTAssertNil(restored.session.pendingProposal)
    }

    @MainActor
    func testFreshLaunchArchivesPreviousConversationAndStartsEmpty() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let store = AgentV2SessionStore(defaults: defaults)
        store.updatePreference(\.pace, value: "packed")
        store.append(.init(id: UUID(), role: "user", content: "上次的对话", createdAt: .now))

        // 重新进入 app（冷启动）：上次对话自动归档，会话从空白开始，偏好延续。
        let relaunched = AgentV2SessionStore(defaults: defaults, startsFreshOnLaunch: true)
        XCTAssertTrue(relaunched.session.messages.isEmpty)
        XCTAssertNil(relaunched.session.draft)
        XCTAssertEqual(relaunched.session.preferences.pace, "packed")
        XCTAssertEqual(relaunched.archives.first?.messages.first?.content, "上次的对话")

        // 上次已是空白会话时再次冷启动：不重复归档。
        let secondLaunch = AgentV2SessionStore(defaults: defaults, startsFreshOnLaunch: true)
        XCTAssertEqual(secondLaunch.archives.count, 1)
        XCTAssertTrue(secondLaunch.session.messages.isEmpty)
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

    private func fliggyStart(_ json: [String: Any]) throws -> AgentV2FliggySearchStart {
        try JSONDecoder().decode(AgentV2FliggySearchStart.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func fliggyCompletion(_ json: [String: Any]) throws -> AgentV2FliggySearchCompletion {
        try JSONDecoder().decode(AgentV2FliggySearchCompletion.self, from: JSONSerialization.data(withJSONObject: json))
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
