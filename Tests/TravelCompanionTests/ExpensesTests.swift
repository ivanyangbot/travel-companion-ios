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
        let shared = ExpenseSnapshot(amountMinor: 10_000, currency: "CNY", category: .transport, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01")
        let selfPaid = ExpenseSnapshot(amountMinor: 6_000, currency: "CNY", category: .food, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-01")
        let settlement = ExpenseSettlementCalculator.calculate([shared, selfPaid])
        XCTAssertEqual(settlement.total, 16_000)
        XCTAssertEqual(settlement.byCategory[.transport], 10_000)
        XCTAssertEqual(settlement.netA, 5_000)
        XCTAssertEqual(settlement.netB, -5_000)
        XCTAssertEqual(ExpenseMoney.formatted(5_000, currency: "CNY").isEmpty, false)
    }

    func testOddMinorUnitEqualSplitDeterministicallyAssignsRemainderToPersonB() {
        let expense = ExpenseSnapshot(amountMinor: 101, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01")
        let settlement = ExpenseSettlementCalculator.calculate([expense])
        XCTAssertEqual(settlement.owedByA, 50)
        XCTAssertEqual(settlement.owedByB, 51)
        XCTAssertEqual(settlement.netA, 51)
        XCTAssertEqual(settlement.netB, -51)
    }

    func testExpensePatchOnlyEncodesExplicitClears() throws {
        let request = ExpenseRequest(amountMinor: 100, fieldsToClear: ["note", "cardId"])
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["amountMinor"] as? Int, 100)
        XCTAssertTrue(object["note"] is NSNull)
        XCTAssertTrue(object["cardId"] is NSNull)
        XCTAssertNil(object["category"])
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
        let local = ExpenseSnapshot(amountMinor: 100, currency: "CNY", category: .food, paidBy: .personA, splitMode: .equal, occurredOn: "2026-10-01", note: "旧备注")
        let request = ExpenseRequest(amountMinor: 250, currency: "CNY", category: .transport, paidBy: .personB, splitMode: .self, occurredOn: "2026-10-02", note: nil, cardID: nil, fieldsToClear: ["note"])

        let updated = ExpenseOptimisticMutation.applying(request, to: local)
        XCTAssertNil(updated.serverID)
        XCTAssertEqual(updated.amountMinor, 250)
        XCTAssertEqual(updated.category, .transport)
        XCTAssertEqual(updated.paidBy, .personB)
        XCTAssertEqual(updated.splitMode, .self)
        XCTAssertNil(updated.note)
        XCTAssertEqual(ExpenseOptimisticMutation.removing(updated, from: [updated]).count, 0)
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
