import CoreLocation
import XCTest
@testable import TravelCompanion

final class TodayWeatherTests: XCTestCase {
    private func point(_ latitude: Double, _ longitude: Double, _ name: String) -> (coordinate: CLLocationCoordinate2D, name: String) {
        (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), name)
    }

    func testEmptyDayProducesNoClusters() {
        XCTAssertTrue(WeatherClusterPlanner.clusters(for: []).isEmpty)
    }

    func testSinglePointIsOneClusterAtThatPoint() {
        let clusters = WeatherClusterPlanner.clusters(for: [point(35.6812, 139.7671, "东京站")])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].center.latitude, 35.6812, accuracy: 0.0001)
        XCTAssertEqual(clusters[0].center.longitude, 139.7671, accuracy: 0.0001)
        XCTAssertEqual(clusters[0].nearestName, "东京站")
        XCTAssertEqual(clusters[0].memberCount, 1)
    }

    func testNearbyPointsCollapseIntoSingleClusterAtGeographicCenter() {
        // 东京站与银座相距约 1.1 公里，远在 2.5 公里半径内。
        let points = [
            point(35.6812, 139.7671, "东京站"),
            point(35.6717, 139.7650, "银座"),
            point(35.6804, 139.7690, "日本桥"),
        ]
        let clusters = WeatherClusterPlanner.clusters(for: points)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberCount, 3)
        // 地理中心应落在三点之间，且任一点都不超过 2.5 公里。
        for item in points {
            XCTAssertLessThanOrEqual(
                WeatherClusterPlanner.distanceMeters(from: clusters[0].center, to: item.coordinate),
                WeatherClusterPlanner.radiusMeters
            )
        }
        XCTAssertEqual(clusters[0].nearestName, "日本桥")
    }

    func testFarApartPointsSplitIntoMultipleClusters() {
        // 东京站—新宿约 6 公里，超出 2.5 公里半径，需要两地天气。
        let points = [
            point(35.6812, 139.7671, "东京站"),
            point(35.6717, 139.7650, "银座"),
            point(35.6895, 139.7004, "新宿"),
        ]
        let clusters = WeatherClusterPlanner.clusters(for: points)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.map(\.memberCount).sorted(), [1, 2])
        // 新宿独成一簇；东京站与银座同簇，中心离两者几乎等距，标签取其一即可。
        let shinjukuCluster = clusters.first { $0.memberCount == 1 }
        XCTAssertEqual(shinjukuCluster?.nearestName, "新宿")
        XCTAssertEqual(shinjukuCluster?.center.latitude ?? 0, 35.6895, accuracy: 0.01)
        let tokyoCluster = clusters.first { $0.memberCount == 2 }
        XCTAssertTrue(["东京站", "银座"].contains(tokyoCluster?.nearestName ?? ""))
    }

    func testBoundaryDistanceStaysInOneCluster() {
        // 以地理中心为参照构造一对恰好不超过半径的点：两点相距略小于 5 公里，
        // 中心在中点，各距中心约 2.49 公里。
        let center = CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0)
        let offset = 0.0224 // 约 2.49 公里的纬度差
        let points = [
            point(center.latitude - offset, center.longitude, "南"),
            point(center.latitude + offset, center.longitude, "北"),
        ]
        let clusters = WeatherClusterPlanner.clusters(for: points)
        XCTAssertEqual(clusters.count, 1)
    }

    func testGeographicCenterAveragesCoordinates() {
        let center = WeatherClusterPlanner.geographicCenter(of: [
            CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0),
            CLLocationCoordinate2D(latitude: 35.0, longitude: 141.0),
        ])
        // 球面质心沿大圆取中点：经度严格居中，纬度因球面几何略微北偏。
        XCTAssertEqual(center.latitude, 35.0, accuracy: 0.01)
        XCTAssertEqual(center.longitude, 140.0, accuracy: 0.001)
    }

    func testDayOffsetBetweenTripDates() {
        XCTAssertEqual(TodayWeatherProvider.dayOffset(from: "2026-07-31", to: "2026-07-31"), 0)
        XCTAssertEqual(TodayWeatherProvider.dayOffset(from: "2026-07-31", to: "2026-08-03"), 3)
        XCTAssertEqual(TodayWeatherProvider.dayOffset(from: "2026-08-02", to: "2026-07-31"), -2)
        // 跨月、跨年
        XCTAssertEqual(TodayWeatherProvider.dayOffset(from: "2026-12-31", to: "2027-01-01"), 1)
        // 无法解析时不提供天气
        XCTAssertNil(TodayWeatherProvider.dayOffset(from: "2026-07-31", to: "2026/08/01"))
        XCTAssertNil(TodayWeatherProvider.dayOffset(from: "", to: "2026-08-01"))
    }
}
