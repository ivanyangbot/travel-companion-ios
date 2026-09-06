import Foundation
import XCTest
@testable import TravelCompanion

final class AgentV2RequestFactoryTests: XCTestCase {
    private func makeTrip(expenses: [ExpenseSnapshot] = []) -> SharedTripSnapshot {
        let card = TravelCardSnapshot(
            serverID: 11,
            dayID: 1,
            kind: .activity,
            title: "浅草寺",
            startAt: Date(timeIntervalSince1970: 1_760_000_000),
            place: PlaceSnapshot(id: 31, name: "浅草寺", address: "东京", latitude: 35.71, longitude: 139.79, placeId: "poi-1", cityCode: nil, updatedAt: .now),
            priceMinor: 2_000,
            priceCurrency: "JPY"
        )
        let day = TripDaySnapshot(serverID: 1, date: "2026-10-01", position: 0, cards: [card])
        return SharedTripSnapshot(
            id: 7,
            destination: "东京",
            startDate: "2026-10-01",
            endDate: "2026-10-03",
            currency: "JPY",
            version: 3,
            updatedAt: .now,
            days: [day],
            expenses: expenses
        )
    }

    private func makeSession() -> AgentV2LocalSession {
        var session = AgentV2LocalSession.empty
        session.messages = [
            AgentV2TurnRequest.Message(id: UUID(), role: "user", content: "记一笔晚餐", createdAt: .now),
            AgentV2TurnRequest.Message(id: UUID(), role: "assistant", content: "好的。", createdAt: .now),
        ]
        return session
    }

    func testLedgerRequestCarriesAgentFieldExpenseAndReferenceSnapshots() throws {
        var trip = makeTrip(expenses: [
            ExpenseSnapshot(
                serverID: 101,
                amountMinor: 6_050,
                currency: "JPY",
                category: .food,
                occurredOn: "2026-10-04",
                spentAt: Date(timeIntervalSince1970: 1_760_000_000),
                purchaseChannel: "大众点评",
                paymentMethod: ExpensePaymentMethod.alipay.rawValue,
                consumerUserID: 42,
                consumerName: "小林",
                note: "客户报销；参考汇率仅供参考",
                paidAt: Date(timeIntervalSince1970: 1_760_000_050),
                cardIDs: [11, 12]
            ),
            ExpenseSnapshot(amountMinor: 999, currency: "JPY", category: .other, occurredOn: "2026-10-01"),  // 离线记录：无 serverID，不下发
        ])
        trip.expenses.append(contentsOf: (1...70).map { index in
            ExpenseSnapshot(serverID: 1000 + index, amountMinor: 100, currency: "JPY", category: .other, occurredOn: "2026-10-0\(index % 3 + 1)")
        })
        let factory = AgentV2TurnRequestFactory(
            agent: .ledger,
            session: makeSession(),
            trip: trip,
            memoItems: AgentV2TurnRequestFactory.memoSnapshot(items: [("买潜水镜", "约 200 元"), ("办签证", nil)]),
            walletItems: AgentV2TurnRequestFactory.walletSnapshot(items: [("招商银行信用卡", nil)])
        )

        let request = factory.makeRequest(message: "记一笔晚餐")

        XCTAssertEqual(request.agent, "ledger")
        XCTAssertEqual(request.intent, "ledger")
        XCTAssertEqual(request.expenses?.count, AgentV2TurnRequestFactory.expenseSnapshotLimit)
        XCTAssertEqual(request.expenses?.first?.id, 101)
        XCTAssertEqual(request.expenses?.first?.note, "客户报销；参考汇率仅供参考")
        XCTAssertNotNil(request.expenses?.first?.spentAt)
        XCTAssertEqual(request.expenses?.first?.purchaseChannel, "大众点评")
        XCTAssertEqual(request.expenses?.first?.paymentMethod, "alipay")
        XCTAssertEqual(request.expenses?.first?.consumerUserId, 42)
        XCTAssertEqual(request.expenses?.first?.consumerName, "小林")
        XCTAssertEqual(request.expenses?.first?.cardIds, [11, 12])
        XCTAssertNotNil(request.expenses?.first?.paidAt)
        XCTAssertNotNil(request.expenses?.first?.createdAt)
        XCTAssertTrue(request.message.hasPrefix("记一笔晚餐"))
        XCTAssertTrue(request.message.contains("Keep expense notes strictly concise"))
        XCTAssertNil(request.journal)
        XCTAssertEqual(request.memos?.first?.title, "买潜水镜")
        XCTAssertEqual(request.walletCards?.first?.title, "招商银行信用卡")
        // 账本上下文需要卡片实际价字段。
        XCTAssertEqual(request.trip?.days.first?.cards.first?.actualPriceMinor, nil)
        XCTAssertEqual(request.trip?.days.first?.cards.first?.priceMinor, 2_000)
        XCTAssertEqual(request.trip?.days.first?.cards.first?.priceCurrency, "JPY")
        // 历史随会话截断携带。
        XCTAssertEqual(request.history.count, 2)
    }

    func testJournalRequestCarriesJournalContextOnly() {
        let journal = AgentV2TurnRequest.JournalContext(
            groups: [.init(id: 5, name: "东京篇")],
            entries: [.init(id: 9, groupId: 5, title: "浅草的傍晚", content: "很安静")]
        )
        let factory = AgentV2TurnRequestFactory(
            agent: .journal,
            session: makeSession(),
            trip: makeTrip(),
            journalContext: journal
        )

        let request = factory.makeRequest(message: "写一篇今天的游记")

        XCTAssertEqual(request.agent, "journal")
        XCTAssertEqual(request.intent, "journal")
        XCTAssertEqual(request.journal?.groups.first?.name, "东京篇")
        XCTAssertEqual(request.journal?.entries.first?.title, "浅草的傍晚")
        XCTAssertNil(request.expenses)
        XCTAssertNil(request.memos)
        XCTAssertNil(request.walletCards)
    }

    func testNoTripFallsBackToPlanNewForEveryAgent() {
        for agent in AgentKind.allCases {
            let factory = AgentV2TurnRequestFactory(
                agent: agent,
                session: makeSession(),
                trip: nil
            )
            let request = factory.makeRequest(message: "帮我规划一段旅程")
            XCTAssertEqual(request.intent, "plan_new")
            XCTAssertEqual(request.agent, "itinerary")
            XCTAssertNil(request.trip)
            XCTAssertNil(request.expenses)
            XCTAssertNil(request.journal)
        }

        // plansNewTrip 显式规划模式同样回退 plan_new。
        let planning = AgentV2TurnRequestFactory(
            agent: .ledger,
            session: makeSession(),
            trip: makeTrip(),
            plansNewTrip: true
        )
        XCTAssertEqual(planning.makeRequest(message: "x").intent, "plan_new")
    }

    func testItineraryRequestKeepsLegacyShape() {
        let factory = AgentV2TurnRequestFactory(
            agent: .itinerary,
            session: makeSession(),
            trip: makeTrip()
        )
        let request = factory.makeRequest(message: "安排第一天")

        XCTAssertEqual(request.intent, "itinerary")
        XCTAssertEqual(request.agent, "itinerary")
        XCTAssertNil(request.expenses)
        XCTAssertNil(request.journal)
        XCTAssertNil(request.memos)
        XCTAssertNil(request.walletCards)
        // 行程 agent 的卡片不携带实际价，保持旧线上格式。
        XCTAssertNil(request.trip?.days.first?.cards.first?.actualPriceMinor)
        XCTAssertEqual(request.trip?.destination, "东京")
    }

    func testExpenseSnapshotSkipsOfflineRecordsAndCaps() {
        var trip = makeTrip()
        trip.expenses = [
            ExpenseSnapshot(serverID: 1, amountMinor: 10, currency: "JPY", category: .food, occurredOn: "2026-10-02"),
            ExpenseSnapshot(amountMinor: 20, currency: "JPY", category: .food, occurredOn: "2026-10-02"),
        ]
        XCTAssertEqual(AgentV2TurnRequestFactory.expenseSnapshot(from: trip).map(\.id), [1])

        trip.expenses = (0..<80).map { index in
            ExpenseSnapshot(serverID: index, amountMinor: 10, currency: "JPY", category: .other, occurredOn: "2026-10-0\(index % 3 + 1)")
        }
        XCTAssertEqual(AgentV2TurnRequestFactory.expenseSnapshot(from: trip).count, 60)
    }

    func testExpenseCandidatePreservesNotesIncludingBookingDetailsAndLongText() throws {
        let id = UUID()
        let originalNotes = "入住时补付押金；Booking订单号 123；待报销。" + String(repeating: "保留原文", count: 30)
        let json = """
        {
          "id": "\(id.uuidString)",
          "kind": "expense",
          "title": "酒店",
          "notes": "\(originalNotes)"
        }
        """
        let candidate = try JSONDecoder().decode(AgentV2Candidate.self, from: Data(json.utf8))
        XCTAssertEqual(candidate.notes, originalNotes)
        let roundTripped = try JSONDecoder().decode(AgentV2Candidate.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(roundTripped.notes, originalNotes)
    }
}
