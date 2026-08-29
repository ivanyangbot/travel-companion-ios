import Foundation
import SwiftData

struct CachedRouteEstimate: Codable, Equatable, Sendable {
    let estimate: RouteEstimate
    let cachedAt: Date

    func isFresh(now: Date = .now, maxAge: TimeInterval = RouteCache.maxAge) -> Bool {
        now.timeIntervalSince(cachedAt) < maxAge
    }
}

@Model
final class RouteCacheRecord {
    @Attribute(.unique) var cacheKey: String
    var encodedValue: Data

    init(cacheKey: String, value: CachedRouteEstimate) throws {
        self.cacheKey = cacheKey
        encodedValue = try JSONEncoder.routeCache.encode(value)
    }

    func value() throws -> CachedRouteEstimate {
        try JSONDecoder.routeCache.decode(CachedRouteEstimate.self, from: encodedValue)
    }
}

@MainActor
final class RouteCache {
    nonisolated static let maxAge: TimeInterval = 15 * 60
    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    static func cacheKey(origin: RoutePoint, destination: RoutePoint, mode: RouteMode) -> String {
        // Rounding keeps GPS noise from defeating the 15-minute cache while
        // preserving better-than-street-level accuracy.
        "\(origin.latitude.rounded(to: 5)),\(origin.longitude.rounded(to: 5))->\(destination.latitude.rounded(to: 5)),\(destination.longitude.rounded(to: 5))@\(mode.rawValue)"
    }

    func cached(origin: RoutePoint, destination: RoutePoint, mode: RouteMode, now: Date = .now, includeExpired: Bool = false) -> CachedRouteEstimate? {
        let key = Self.cacheKey(origin: origin, destination: destination, mode: mode)
        guard let record = try? modelContext.fetch(FetchDescriptor<RouteCacheRecord>()).first(where: { $0.cacheKey == key }),
              let value = try? record.value(), includeExpired || value.isFresh(now: now) else { return nil }
        return value
    }

    func store(_ estimate: RouteEstimate, origin: RoutePoint, destination: RoutePoint, mode: RouteMode, cachedAt: Date = .now) throws {
        let key = Self.cacheKey(origin: origin, destination: destination, mode: mode)
        let value = CachedRouteEstimate(estimate: estimate, cachedAt: cachedAt)
        if let record = try modelContext.fetch(FetchDescriptor<RouteCacheRecord>()).first(where: { $0.cacheKey == key }) {
            record.encodedValue = try JSONEncoder.routeCache.encode(value)
        } else {
            modelContext.insert(try RouteCacheRecord(cacheKey: key, value: value))
        }
        try modelContext.save()
    }

    /// Route estimates remain available across launches until the user uses
    /// the page-level refresh action. Travel-mode preferences are stored in a
    /// separate model and intentionally survive this invalidation.
    func removeAll() throws {
        let records = try modelContext.fetch(FetchDescriptor<RouteCacheRecord>())
        for record in records {
            modelContext.delete(record)
        }
        try modelContext.save()
    }
}

private extension Double {
    func rounded(to decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (self * factor).rounded() / factor
    }
}

private extension JSONEncoder {
    static let routeCache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let routeCache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
