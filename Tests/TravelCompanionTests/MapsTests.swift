import XCTest
import SwiftData
@testable import TravelCompanion

final class MapsTests: XCTestCase {
    func testRouteCacheEntryExpiresAfterFifteenMinutes() {
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let entry = CachedRouteEstimate(estimate: estimate, cachedAt: cachedAt)

        XCTAssertTrue(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge - 1)))
        XCTAssertFalse(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge)))
    }

    func testRouteModeUsesAppleMapsDirectionValues() {
        XCTAssertEqual(RouteMode.driving.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeDriving")
        XCTAssertEqual(RouteMode.walking.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeWalking")
        XCTAssertEqual(RouteMode.transit.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeTransit")
    }

    @MainActor
    func testExpiredCacheCanBeReadOnlyAsNetworkFallback() throws {
        let container = try ModelContainer(for: Schema([RouteCacheRecord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cache = RouteCache(modelContext: container.mainContext)
        let origin = RoutePoint(latitude: 39.9, longitude: 116.3)
        let destination = RoutePoint(latitude: 39.8, longitude: 116.4)
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let staleAt = Date.now.addingTimeInterval(-RouteCache.maxAge)

        try cache.store(estimate, origin: origin, destination: destination, mode: .walking, cachedAt: staleAt)

        XCTAssertNil(cache.cached(origin: origin, destination: destination, mode: .walking))
        let fallback = try XCTUnwrap(cache.cached(origin: origin, destination: destination, mode: .walking, includeExpired: true)?.estimate)
        XCTAssertEqual(fallback.distanceMeters, estimate.distanceMeters)
        XCTAssertEqual(fallback.durationSeconds, estimate.durationSeconds)
        XCTAssertEqual(fallback.mode, estimate.mode)
        XCTAssertEqual(fallback.source, estimate.source)
    }

    @MainActor
    func testCardLegPreferenceDefaultsToDrivingAndPersistsAcrossLegs() throws {
        let container = try ModelContainer(for: Schema([CardLegPreference.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CardLegStore(modelContext: container.mainContext)
        let origin = TravelCardSnapshot(dayID: 1, kind: .activity, title: "故宫", startAt: .now)
        let destination = TravelCardSnapshot(dayID: 1, kind: .activity, title: "天坛", startAt: .now)
        let key = CardLegStore.legKey(origin: origin, destination: destination)

        XCTAssertEqual(store.mode(for: key), .driving)

        store.setMode(.transit, for: key)
        XCTAssertEqual(store.mode(for: key), .transit)

        store.setMode(.walking, for: key)
        XCTAssertEqual(store.mode(for: key), .walking)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CardLegPreference>()).count, 1)
    }
}
