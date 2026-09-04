import Foundation
import SwiftData

/// 本机记录某两段卡片之间用户偏好的默认出行方式。仅保存在本设备，不与服务器同步，
/// 与卡包/路线缓存一致保持本机私有。`legKey` 用相邻两张卡片的本地 UUID 拼接，
/// 卡片重排后若再次相邻即可复用同一偏好。
@Model
final class CardLegPreference {
    @Attribute(.unique) var legKey: String
    var travelMode: String
    /// Route keys that Apple Maps could not estimate. Keeping failures beside
    /// the leg preference prevents a recycled list row from retrying every
    /// time it enters the viewport. The page-level refresh action clears them.
    var failedRouteKeys: String = ""
    /// Manual durations are keyed by coordinates and travel mode, independently of map estimates.
    var manualDurationsJSON: String = "{}"
    var createdAt: Date
    var updatedAt: Date

    init(legKey: String, travelMode: RouteMode = .driving) {
        self.legKey = legKey
        self.travelMode = travelMode.rawValue
        self.failedRouteKeys = ""
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@MainActor
final class CardLegStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    static func legKey(origin: TravelCardSnapshot, destination: TravelCardSnapshot) -> String {
        "\(origin.id.uuidString)->\(destination.id.uuidString)"
    }

    func mode(for legKey: String) -> RouteMode {
        guard let record = try? modelContext.fetch(FetchDescriptor<CardLegPreference>()).first(where: { $0.legKey == legKey }),
              let mode = RouteMode(rawValue: record.travelMode) else { return .driving }
        return mode
    }

    func setMode(_ mode: RouteMode, for legKey: String) {
        if let record = try? modelContext.fetch(FetchDescriptor<CardLegPreference>()).first(where: { $0.legKey == legKey }) {
            record.travelMode = mode.rawValue
            record.updatedAt = .now
        } else {
            modelContext.insert(CardLegPreference(legKey: legKey, travelMode: mode))
        }
        try? modelContext.save()
    }

    func hasEstimateFailure(routeKey: String, for legKey: String) -> Bool {
        guard let record = record(for: legKey) else { return false }
        return Self.failedRouteKeySet(record.failedRouteKeys).contains(routeKey)
    }

    func manualDuration(routeKey: String, for legKey: String) -> Int? {
        guard let record = record(for: legKey),
              let data = record.manualDurationsJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: Int].self, from: data),
              let seconds = values[routeKey], seconds > 0 else { return nil }
        return seconds
    }

    func setManualDuration(_ seconds: Int?, routeKey: String, for legKey: String) throws {
        guard seconds == nil || (1...172_740).contains(seconds!) else { return }
        let existing = record(for: legKey)
        let value = existing ?? CardLegPreference(legKey: legKey)
        let previous = value.manualDurationsJSON
        var durations = (try? JSONDecoder().decode([String: Int].self, from: Data(previous.utf8))) ?? [:]
        durations[routeKey] = seconds
        value.manualDurationsJSON = String(decoding: try JSONEncoder().encode(durations), as: UTF8.self)
        if existing == nil { modelContext.insert(value) }
        do {
            try modelContext.save()
        } catch {
            value.manualDurationsJSON = previous
            if existing == nil { modelContext.delete(value) }
            throw error
        }
    }

    func markEstimateFailure(routeKey: String, for legKey: String) {
        let record = record(for: legKey) ?? {
            let value = CardLegPreference(legKey: legKey)
            modelContext.insert(value)
            return value
        }()
        var keys = Self.failedRouteKeySet(record.failedRouteKeys)
        guard keys.insert(routeKey).inserted else { return }
        record.failedRouteKeys = keys.sorted().joined(separator: "\n")
        record.updatedAt = .now
        try? modelContext.save()
    }

    func clearEstimateFailure(routeKey: String, for legKey: String) {
        guard let record = record(for: legKey) else { return }
        var keys = Self.failedRouteKeySet(record.failedRouteKeys)
        guard keys.remove(routeKey) != nil else { return }
        record.failedRouteKeys = keys.sorted().joined(separator: "\n")
        record.updatedAt = .now
        try? modelContext.save()
    }

    func clearAllEstimateFailures() {
        guard let records = try? modelContext.fetch(FetchDescriptor<CardLegPreference>()) else { return }
        var changed = false
        for record in records where !record.failedRouteKeys.isEmpty {
            record.failedRouteKeys = ""
            record.updatedAt = .now
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    private func record(for legKey: String) -> CardLegPreference? {
        try? modelContext.fetch(FetchDescriptor<CardLegPreference>()).first(where: { $0.legKey == legKey })
    }

    private static func failedRouteKeySet(_ value: String) -> Set<String> {
        Set(value.split(separator: "\n").map(String.init))
    }
}
