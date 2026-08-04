import Foundation
import SwiftData

@MainActor
final class SharedTripRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cachedTrip(id: Int? = nil) throws -> SharedTripSnapshot? {
        let mirrors = try modelContext.fetch(FetchDescriptor<SharedTripMirror>())
        let mirror = id.flatMap { requestedID in mirrors.first { $0.tripID == requestedID } } ?? (id == nil ? mirrors.first : nil)
        return try mirror?.snapshot()
    }

    func cachedTrips() throws -> [SharedTripSnapshot] {
        try modelContext.fetch(
            FetchDescriptor<SharedTripMirror>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        ).map { try $0.snapshot() }
    }

    /// Local trips use negative IDs until the first authenticated import gives
    /// them server IDs. Computing the next value from persisted mirrors keeps
    /// IDs stable across launches and avoids collisions between local trips.
    func nextLocalTripID() throws -> Int {
        let lowest = try modelContext.fetch(FetchDescriptor<SharedTripMirror>())
            .map(\.tripID)
            .filter { $0 < 0 }
            .min() ?? 0
        return min(-1, lowest - 1)
    }

    func save(_ snapshot: SharedTripSnapshot) throws {
        if let mirror = try modelContext.fetch(FetchDescriptor<SharedTripMirror>()).first(where: { $0.tripID == snapshot.id }) {
            try mirror.replace(with: snapshot)
        } else {
            modelContext.insert(try SharedTripMirror(snapshot: snapshot))
        }
        try modelContext.save()
    }

    @discardableResult
    func enqueue(method: String, path: String, tripID: Int, body: Data, baseVersion: Int, clientEntityID: UUID? = nil) throws -> PendingOperation {
        let operation = PendingOperation(method: method, path: path, tripID: tripID, body: body, baseVersion: baseVersion, clientEntityID: clientEntityID)
        modelContext.insert(operation)
        try modelContext.save()
        return operation
    }

    func pendingOperations() throws -> [PendingOperation] {
        try allOperations().filter { $0.terminalError == nil }
    }

    func remove(_ operation: PendingOperation) throws {
        modelContext.delete(operation)
        try modelContext.save()
    }

    /// A completed first-login import already materialized the optimistic
    /// snapshot on the new server trip, so its old per-resource operations
    /// must not be replayed against the retired local trip ID.
    func discardOperations(for tripID: Int) throws {
        let operations = try allOperations().filter { $0.tripID == tripID }
        let draftIDs = Set(operations.compactMap(\.clientEntityID))
        for operation in operations { modelContext.delete(operation) }
        for draft in try confirmedAIDraftCards() where draftIDs.contains(draft.localID) {
            modelContext.delete(draft)
        }
        try modelContext.save()
    }

    func removeCachedTrip(id: Int) throws {
        let mirrors = try modelContext.fetch(FetchDescriptor<SharedTripMirror>())
        for mirror in mirrors where mirror.tripID == id { modelContext.delete(mirror) }
        try modelContext.save()
    }

    func incrementRetry(_ operation: PendingOperation) throws {
        operation.retryCount += 1
        try modelContext.save()
    }

    func markTerminal(_ operation: PendingOperation, message: String) throws {
        operation.terminalError = message
        try modelContext.save()
    }

    func pendingOperation(for clientEntityID: UUID) throws -> PendingOperation? {
        try pendingOperations().first { $0.clientEntityID == clientEntityID }
    }

    func replaceBody(_ operation: PendingOperation, with body: Data) throws {
        operation.body = body
        try modelContext.save()
    }

    func queueConfirmedAIDraftCards(_ cards: [AIItineraryDraft.Card]) throws {
        for card in cards where card.isSelected {
            if let operation = try operationIncludingTerminal(for: card.id), operation.terminalError != nil {
                // A known rejected request was not applied remotely, so user
                // edits may safely replace it with a new idempotent operation.
                modelContext.delete(operation)
            }
let placeData = try card.place.map { try JSONEncoder().encode($0) }
let extraData = try card.extras.map { try JSONEncoder().encode($0) }
let persisted = try confirmedAIDraftCards().first { $0.localID == card.id }
let target = persisted ?? ConfirmedAIDraftCard(
localID: card.id,
date: card.date,
kind: card.kind.rawValue,
title: card.title.trimmingCharacters(in: .whitespacesAndNewlines),
time: card.time?.trimmingCharacters(in: .whitespacesAndNewlines),
placeData: placeData,
notes: card.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
extraData: extraData
)
target.date = card.date
target.kind = card.kind.rawValue
target.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
target.time = card.time?.trimmingCharacters(in: .whitespacesAndNewlines)
target.placeData = placeData
target.notes = card.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
target.extraData = extraData

            if persisted == nil { modelContext.insert(target) }
        }
        try modelContext.save()
    }

    func confirmedAIDraftCards() throws -> [ConfirmedAIDraftCard] {
        try modelContext.fetch(FetchDescriptor<ConfirmedAIDraftCard>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func removeConfirmedAIDraftCard(_ card: ConfirmedAIDraftCard) throws {
        modelContext.delete(card)
        try modelContext.save()
    }

    func removeConfirmedAIDraftCard(for clientEntityID: UUID?) throws {
        guard let clientEntityID,
              let card = try confirmedAIDraftCards().first(where: { $0.localID == clientEntityID }) else { return }
        try removeConfirmedAIDraftCard(card)
    }

    private func allOperations() throws -> [PendingOperation] {
        try modelContext.fetch(FetchDescriptor<PendingOperation>(sortBy: [SortDescriptor(\PendingOperation.createdAt)]))
    }

    private func operationIncludingTerminal(for clientEntityID: UUID) throws -> PendingOperation? {
        try allOperations().first { $0.clientEntityID == clientEntityID }
    }
}
