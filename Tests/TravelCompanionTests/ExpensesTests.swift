import XCTest
import SwiftData
@testable import TravelCompanion

final class ExpensesTests: XCTestCase {
    func testMinorUnitParsingRejectsPrecisionLossAndInvalidAmounts() {
        XCTAssertEqual(ExpenseMoney.amountMinor(from: "100.25", currency: "CNY"), 10_025)
        XCTAssertEqual(ExpenseMoney.amountMinor(from: "100", currency: "JPY"), 100)
        XCTAssertNil(ExpenseMoney.amountMinor(from: "0", currency: "CNY"))
        XCTAssertNil(ExpenseMoney.amountMinor(from: "1.001", currency: "CNY"))
        XCTAssertNil(ExpenseMoney.amountMinor(from: "-2", currency: "CNY"))
    }

    func testEditorAmountRoundTripsWithCanonicalSeparatorAndZeroOrThreeFractionCurrencies() {
        XCTAssertEqual(ExpenseMoney.inputString(10_025, currency: "CNY"), "100.25")
        XCTAssertEqual(ExpenseMoney.amountMinor(from: ExpenseMoney.inputString(10_025, currency: "CNY"), currency: "CNY"), 10_025)
        XCTAssertEqual(ExpenseMoney.inputString(123, currency: "JPY"), "123")
        XCTAssertEqual(ExpenseMoney.amountMinor(from: ExpenseMoney.inputString(123, currency: "JPY"), currency: "JPY"), 123)
        XCTAssertEqual(ExpenseMoney.inputString(12_345, currency: "KWD"), "12.345")
        XCTAssertEqual(ExpenseMoney.amountMinor(from: ExpenseMoney.inputString(12_345, currency: "KWD"), currency: "KWD"), 12_345)
    }

    func testSettlementForSharedAndSelfExpenses() {
        let shared = ExpenseSnapshot(amountMinor: 10_000, currency: "CNY", category: .transport, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01", paidAt: .distantPast)
        let selfPaid = ExpenseSnapshot(amountMinor: 6_000, currency: "CNY", category: .food, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-01", paidAt: .distantPast)
        let settlement = ExpenseSettlementCalculator.calculate([shared, selfPaid])
        XCTAssertEqual(settlement.total, 16_000)
        XCTAssertEqual(settlement.byCategory[.transport], 10_000)
        XCTAssertEqual(settlement.netA, 5_000)
        XCTAssertEqual(settlement.netB, -5_000)
        XCTAssertEqual(ExpenseMoney.formatted(5_000, currency: "CNY").isEmpty, false)
    }

    func testSettlementIgnoresUnpaidExpensesUntilPaidAtPasses() {
        let paid = ExpenseSnapshot(amountMinor: 10_000, currency: "CNY", category: .transport, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01", paidAt: .distantPast)
        // 到店付：预计支付时间在未来 → 未支出，不进入结算。
        let scheduled = ExpenseSnapshot(amountMinor: 8_000, currency: "CNY", category: .lodging, paidBy: .personB, splitMode: .equal, occurredOn: "2026-10-02", paidAt: .distantFuture)
        let noDate = ExpenseSnapshot(amountMinor: 5, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-02")
        let settlement = ExpenseSettlementCalculator.calculate([paid, scheduled, noDate])
        XCTAssertEqual(settlement.total, 10_000)
        XCTAssertEqual(settlement.owedByB, 5_000)
    }

    func testIsPaidDerivesFromPaymentDateVersusNow() {
        let now = Date()
        XCTAssertTrue(ExpenseSnapshot(amountMinor: 1, currency: "CNY", category: .food, occurredOn: "2026-10-01", paidAt: now.addingTimeInterval(-1)).isPaid(at: now))
        XCTAssertFalse(ExpenseSnapshot(amountMinor: 1, currency: "CNY", category: .food, occurredOn: "2026-10-01", paidAt: now.addingTimeInterval(60)).isPaid(at: now))
        XCTAssertFalse(ExpenseSnapshot(amountMinor: 1, currency: "CNY", category: .food, occurredOn: "2026-10-01").isPaid(at: now))
        // 跨过预计支付时刻后自动视为已支出。
        XCTAssertTrue(ExpenseSnapshot(amountMinor: 1, currency: "CNY", category: .food, occurredOn: "2026-10-01", paidAt: now.addingTimeInterval(60)).isPaid(at: now.addingTimeInterval(61)))
    }

    func testSettlementUsesConvertedSnapshotInsteadOfAddingDifferentCurrencies() {
        let hkd = ExpenseSnapshot(
            amountMinor: 132_092,
            currency: "HKD",
            settlementAmountMinor: 257_579_400,
            settlementCurrency: "IDR",
            exchangeRate: "1950.00",
            exchangeRateAsOf: "2026-09-01",
            exchangeRateSource: "frankfurter",
            category: .lodging,
            occurredOn: "2026-09-24",
            paidAt: .distantPast
        )
        let idr = ExpenseSnapshot(amountMinor: 100_000, currency: "IDR", category: .food, occurredOn: "2026-09-24", paidAt: .distantPast)
        let settlement = ExpenseSettlementCalculator.calculate([hkd, idr])
        XCTAssertEqual(settlement.total, 257_679_400)
        XCTAssertEqual(settlement.byCategory[.lodging], 257_579_400)
    }

    func testOddMinorUnitEqualSplitDeterministicallyAssignsRemainderToPersonB() {
        let expense = ExpenseSnapshot(amountMinor: 101, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01", paidAt: .distantPast)
        let settlement = ExpenseSettlementCalculator.calculate([expense])
        XCTAssertEqual(settlement.owedByA, 50)
        XCTAssertEqual(settlement.owedByB, 51)
        XCTAssertEqual(settlement.netA, 51)
        XCTAssertEqual(settlement.netB, -51)
    }

    func testExpensePatchOnlyEncodesExplicitClears() throws {
        let request = ExpenseRequest(amountMinor: 100, fieldsToClear: ["note", "cardIds", "purchaseChannel", "paymentMethod", "consumerUserId", "consumerName", "paidAt"])
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["amountMinor"] as? Int, 100)
        XCTAssertTrue(object["note"] is NSNull)
        XCTAssertTrue(object["cardIds"] is NSNull)
        XCTAssertTrue(object["purchaseChannel"] is NSNull)
        XCTAssertTrue(object["paymentMethod"] is NSNull)
        XCTAssertTrue(object["consumerUserId"] is NSNull)
        XCTAssertTrue(object["consumerName"] is NSNull)
        XCTAssertTrue(object["paidAt"] is NSNull)
        XCTAssertNil(object["category"])
    }

    func testExpenseRequestEncodesStructuredTransactionDetails() throws {
        let spentAt = Date(timeIntervalSince1970: 1_760_000_000)
        let request = ExpenseRequest(
            amountMinor: 8_800,
            spentAt: spentAt,
            purchaseChannel: "Grab",
            paymentMethod: ExpensePaymentMethod.creditCard.rawValue,
            consumerUserID: 7,
            consumerName: "Mina"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        XCTAssertNotNil(object["spentAt"] as? String)
        XCTAssertEqual(object["purchaseChannel"] as? String, "Grab")
        XCTAssertEqual(object["paymentMethod"] as? String, "credit_card")
        XCTAssertEqual(object["consumerUserId"] as? Int, 7)
        XCTAssertEqual(object["consumerName"] as? String, "Mina")
    }

    func testSettlementSaturatesInsteadOfOverflowing() {
        let first = ExpenseSnapshot(amountMinor: Int64.max, currency: "CNY", category: .other, paidBy: .personA, splitMode: .self, occurredOn: "2026-10-01")
        let second = ExpenseSnapshot(amountMinor: Int64.max, currency: "CNY", category: .other, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-02")
        let settlement = ExpenseSettlementCalculator.calculate([first, second])
        XCTAssertTrue(settlement.overflowed)
        XCTAssertEqual(settlement.total, Int64.max)
        XCTAssertLessThanOrEqual(abs(settlement.netA), Int64.max)
    }

    @MainActor
    func testPrimaryCurrencyCanChangeFromLedgerAndInvalidatesStaleConversions() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: configuration
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )

        await engine.bootstrap()
        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        await engine.saveSetup(destination: "东京", startDate: start, endDate: start, currency: "CNY")
        await engine.addExpense(
            ExpenseRequest(amountMinor: 10_000, currency: "CNY", category: .food, occurredOn: "2026-10-01")
        )

        await engine.updatePrimaryCurrency("usd")

        XCTAssertEqual(engine.trip?.currency, "USD")
        let expense = try XCTUnwrap(engine.trip?.expenses.first)
        XCTAssertEqual(expense.settlementCurrency, "USD")
        XCTAssertNil(expense.settlementAmountMinor)
        XCTAssertNil(expense.amountForSettlement)
        XCTAssertEqual(try repository.cachedTrip(id: try XCTUnwrap(engine.trip?.id))?.currency, "USD")
    }

    @MainActor
    func testOfflineExpenseOperationCanBeUpdatedAndCancelledByLocalIdentity() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SharedTripMirror.self, PendingOperation.self, configurations: configuration)
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let localExpenseID = UUID()
        try repository.enqueue(method: "POST", path: "/v1/expenses", tripID: 1, body: Data("old".utf8), baseVersion: 3, clientEntityID: localExpenseID)

        let pending = try XCTUnwrap(repository.pendingOperation(for: localExpenseID))
        try repository.replaceBody(pending, with: Data("edited".utf8))
        XCTAssertEqual(String(data: try XCTUnwrap(repository.pendingOperation(for: localExpenseID)).body, encoding: .utf8), "edited")

        try repository.remove(pending)
        XCTAssertNil(try repository.pendingOperation(for: localExpenseID))
    }

    func testOptimisticExpenseUpdateAndCancelUseTheLocalSnapshotBeforeServerID() {
        let local = ExpenseSnapshot(amountMinor: 100, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01", note: "旧备注", cardIDs: [11])
        let spentAt = Date(timeIntervalSince1970: 1_760_000_000)
        let paidAt = Date(timeIntervalSince1970: 1_760_000_100)
        let request = ExpenseRequest(amountMinor: 250, currency: "CNY", category: .transport, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-02", spentAt: spentAt, paidAt: paidAt, purchaseChannel: "Grab", paymentMethod: ExpensePaymentMethod.creditCard.rawValue, consumerUserID: 9, consumerName: "Mina", note: nil, cardIDs: [12, 13], fieldsToClear: ["note"])

        let updated = ExpenseOptimisticMutation.applying(request, to: local)
        XCTAssertNil(updated.serverID)
        XCTAssertEqual(updated.amountMinor, 250)
        XCTAssertEqual(updated.category, .transport)
        XCTAssertEqual(updated.paidBy, .personB)
        XCTAssertEqual(updated.splitMode, .self)
        XCTAssertEqual(updated.spentAt, spentAt)
        XCTAssertEqual(updated.paidAt, paidAt)
        XCTAssertEqual(updated.purchaseChannel, "Grab")
        XCTAssertEqual(updated.paymentMethod, "credit_card")
        XCTAssertEqual(updated.consumerUserID, 9)
        XCTAssertEqual(updated.consumerName, "Mina")
        XCTAssertEqual(updated.cardIDs, [12, 13])
        XCTAssertNil(updated.note)
        XCTAssertEqual(ExpenseOptimisticMutation.removing(updated, from: [updated]).count, 0)
    }

    func testOptimisticCardLinkClearResetsToEmptyArray() {
        let local = ExpenseSnapshot(amountMinor: 100, currency: "CNY", category: .food, occurredOn: "2026-10-01", cardIDs: [11, 12])
        let updated = ExpenseOptimisticMutation.applying(
            ExpenseRequest(amountMinor: 100, cardIDs: nil, fieldsToClear: ["cardIds"]),
            to: local
        )
        XCTAssertEqual(updated.cardIDs, [])
    }

    func testCardIDsDecodeFallsBackToLegacySingleCardId() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let paidAtISO = "2026-10-02T02:00:00Z"

        let modern = try decoder.decode(ExpenseSnapshot.self, from: Data("""
        {"id": 9, "amountMinor": 500, "currency": "CNY", "category": "food", "occurredOn": "2026-10-01",
         "cardIds": [3, 5, 7], "paidAt": "\(paidAtISO)", "updatedAt": "2026-10-02T03:00:00Z"}
        """.utf8))
        XCTAssertEqual(modern.cardIDs, [3, 5, 7])
        XCTAssertEqual(modern.paidAt, ISO8601DateFormatter().date(from: paidAtISO))

        let legacy = try decoder.decode(ExpenseSnapshot.self, from: Data("""
        {"id": 8, "amountMinor": 500, "currency": "CNY", "category": "food", "occurredOn": "2026-10-01",
         "cardId": 4, "updatedAt": "2026-10-02T03:00:00Z"}
        """.utf8))
        XCTAssertEqual(legacy.cardIDs, [4])
        XCTAssertNil(legacy.paidAt)
    }

    func testListFilterFiltersByConsumerStatusCategoryAndSorts() {
        let now = Date()
        let minaPaid = ExpenseSnapshot(amountMinor: 1_000, currency: "CNY", category: .food, occurredOn: "2026-10-03", paidAt: now.addingTimeInterval(-60))
        minaPaid.consumerUserID = 1
        let ivanUnpaid = ExpenseSnapshot(amountMinor: 500, currency: "CNY", category: .lodging, occurredOn: "2026-10-01", paidAt: now.addingTimeInterval(600))
        ivanUnpaid.consumerUserID = 2
        let freeNamePaid = ExpenseSnapshot(amountMinor: 300, currency: "CNY", category: .transport, occurredOn: "2026-10-02", paidAt: now.addingTimeInterval(-60))
        freeNamePaid.consumerName = "阿猫"
        let expenses = [minaPaid, ivanUnpaid, freeNamePaid]

        let memberOption = ExpenseListFilter.ConsumerOption(id: "member:1", name: "Mina")
        XCTAssertEqual(ExpenseListFilter(consumer: memberOption).apply(to: expenses).map(\.amountMinor), [1_000])
        XCTAssertEqual(ExpenseListFilter(paymentStatus: .unpaid).apply(to: expenses).map(\.amountMinor), [500])
        XCTAssertEqual(ExpenseListFilter(paymentStatus: .paid).apply(to: expenses).map(\.amountMinor), [1_000, 300])
        XCTAssertEqual(ExpenseListFilter(category: .lodging).apply(to: expenses).map(\.amountMinor), [500])
        XCTAssertEqual(ExpenseListFilter(sortOrder: .amountAsc).apply(to: expenses).map(\.amountMinor), [300, 500, 1_000])
        XCTAssertEqual(ExpenseListFilter(sortOrder: .timeAsc).apply(to: expenses).map(\.occurredOn), ["2026-10-01", "2026-10-02", "2026-10-03"])

        let options = ExpenseListFilter.consumerOptions(
            from: expenses,
            members: [TripMemberSummary(userId: 2, displayName: "Ivan", email: nil, role: "editor", joinedAt: now)]
        )
        XCTAssertEqual(options.map(\.id), ["member:2", "member:1", "name:阿猫"])
    }

    func testLegacyConsumerNameMergesWithMatchingMemberIdentity() {
        let expense = ExpenseSnapshot(
            amountMinor: 300,
            currency: "CNY",
            category: .lodging,
            occurredOn: "2026-10-01"
        )
        expense.consumerName = "  sanx 4 "
        let members = [
            TripMemberSummary(
                userId: 4,
                displayName: "sanx 4",
                email: nil,
                role: "editor",
                joinedAt: .now
            )
        ]

        XCTAssertEqual(
            ExpenseListFilter.ConsumerOption.key(of: expense, members: members),
            "member:4"
        )
        let memberOption = ExpenseListFilter.ConsumerOption(id: "member:4", name: "sanx 4")
        XCTAssertEqual(
            ExpenseListFilter(consumer: memberOption).apply(to: [expense], members: members).count,
            1
        )
    }

    @MainActor
    func testSyncEngineEditsAndCancelsAnOfflineExpenseBeforeItHasServerID() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SharedTripMirror.self, PendingOperation.self, configurations: configuration)
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let expense = ExpenseSnapshot(amountMinor: 100, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01")
        let snapshot = SharedTripSnapshot(id: 1, destination: "东京", startDate: "2026-10-01", endDate: "2026-10-02", currency: "CNY", version: 3, updatedAt: .now, days: [], expenses: [expense])
        try repository.save(snapshot)
        try repository.enqueue(method: "POST", path: "/v1/expenses", tripID: 1, body: Data("{}".utf8), baseVersion: 3, clientEntityID: expense.id)
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: true
        )
        await engine.bootstrap()
        let beforeUpdate = try XCTUnwrap(repository.pendingOperation(for: expense.id))
        XCTAssertEqual(beforeUpdate.method, "POST")
        XCTAssertEqual(beforeUpdate.path, "/v1/expenses")
        let cachedExpense = try XCTUnwrap(engine.trip?.expenses.first)

        let request = ExpenseRequest(amountMinor: 250, currency: "CNY", category: .transport, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-02", note: "离线更新")
        await engine.updateExpense(cachedExpense, request: request)
        guard case .offline = engine.status else {
            XCTFail("Expected offline pending state after local update, got \(engine.status)")
            return
        }
        let queued = try XCTUnwrap(repository.pendingOperation(for: cachedExpense.id))
        let queuedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: queued.body) as? [String: Any])
        XCTAssertEqual(queuedBody["amountMinor"] as? Int, 250)
        XCTAssertEqual(engine.trip?.expenses.first?.amountMinor, 250)
        XCTAssertEqual(engine.trip?.expenses.first?.serverID, nil)

        let updated = try XCTUnwrap(engine.trip?.expenses.first)
        await engine.deleteExpense(updated)
        XCTAssertTrue(engine.trip?.expenses.isEmpty == true)
        XCTAssertNil(try repository.pendingOperation(for: cachedExpense.id))
        XCTAssertEqual(engine.status, .synced)
    }
}
