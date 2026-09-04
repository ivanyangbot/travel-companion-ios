import Foundation
import XCTest
@testable import TravelCompanion

/// 「当地时间」换算口径：机票起降用机场时区、酒店/景点近似用最近的带时区
/// 机场、都没有时退回设备时区。格式化输出依赖系统语言，断言全部对照同配置
/// 的本地 DateFormatter，不写死字面量。
final class ItineraryLocalTimeTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let london = TimeZone(identifier: "Europe/London")!

    private func shortTimeFormatter(for timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = timeZone
        return formatter
    }

    private func airportLocation(
        latitude: Double,
        longitude: Double,
        timeZone: String?
    ) -> FlightAirportLocationSnapshot {
        FlightAirportLocationSnapshot(
            query: "airport",
            iata: nil,
            icao: nil,
            name: "Airport",
            city: nil,
            country: nil,
            latitude: latitude,
            longitude: longitude,
            timeZone: timeZone,
            resolvedAt: .now
        )
    }

    private func flight(
        from: FlightAirportLocationSnapshot?,
        to: FlightAirportLocationSnapshot?,
        startAt: Date = .now
    ) -> TravelCardSnapshot {
        TravelCardSnapshot(
            dayID: 1,
            kind: .flight,
            title: "Flight",
            startAt: startAt,
            fromAirportLocation: from,
            toAirportLocation: to
        )
    }

    private func activityAt(
        latitude: Double?,
        longitude: Double?
    ) -> TravelCardSnapshot {
        TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Activity",
            startAt: .now,
            place: PlaceSnapshot(
                id: 1,
                name: "Activity",
                address: nil,
                latitude: latitude,
                longitude: longitude,
                placeId: nil,
                cityCode: nil,
                businessHours: nil,
                updatedAt: .now
            )
        )
    }

    func testFlightStartAndEndUseTheirOwnAirportTimeZones() {
        // 伦敦 01:00 起飞（UTC）、东京 10:30 到达——起降各自按机场时区。
        let startAt = Date(timeIntervalSince1970: 0)
        let card = flight(
            from: airportLocation(latitude: 51.47, longitude: -0.45, timeZone: "Europe/London"),
            to: airportLocation(latitude: 35.55, longitude: 139.78, timeZone: "Asia/Tokyo"),
            startAt: startAt
        )

        XCTAssertEqual(ItineraryLocalTime.startTimeZone(for: card), london)
        XCTAssertEqual(ItineraryLocalTime.endTimeZone(for: card), tokyo)
        XCTAssertEqual(
            ItineraryLocalTime.shortTime(startAt, in: ItineraryLocalTime.startTimeZone(for: card)),
            shortTimeFormatter(for: london).string(from: startAt)
        )
        XCTAssertEqual(
            ItineraryLocalTime.shortTime(startAt, in: ItineraryLocalTime.endTimeZone(for: card)),
            shortTimeFormatter(for: tokyo).string(from: startAt)
        )
    }

    func testFlightWithoutAirportTimeZoneFallsBackToDeviceTimeZone() {
        let card = flight(
            from: airportLocation(latitude: 51.47, longitude: -0.45, timeZone: nil),
            to: nil
        )

        XCTAssertEqual(
            ItineraryLocalTime.startTimeZone(for: card).identifier,
            ItineraryLocalTime.deviceTimeZone.identifier
        )
        XCTAssertEqual(
            ItineraryLocalTime.endTimeZone(for: card).identifier,
            ItineraryLocalTime.deviceTimeZone.identifier
        )
    }

    func testNearestAirportTimeZonePicksTheClosestResolvedAirport() {
        // 同一天里有两班已解析航班（东京、洛杉矶），景点在东京市区：
        // 应取东京机场的时区。
        let haneda = flight(
            from: airportLocation(latitude: 35.55, longitude: 139.78, timeZone: "Asia/Tokyo"),
            to: nil
        )
        let lax = flight(
            from: airportLocation(latitude: 33.94, longitude: -118.41, timeZone: "America/Los_Angeles"),
            to: nil
        )
        let day = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [haneda, lax])
        let shibuya = activityAt(latitude: 35.66, longitude: 139.70)

        XCTAssertEqual(ItineraryLocalTime.nearestAirportTimeZone(for: shibuya, in: [day]), tokyo)
        XCTAssertEqual(ItineraryLocalTime.timeZoneByCardID(in: [day])[shibuya.id], tokyo)
    }

    func testNearestAirportTimeZoneRejectsAirportsBeyondRadius() {
        // 行程里只有洛杉矶机场，景点在伦敦：超过 300km 不近似。
        let lax = flight(
            from: airportLocation(latitude: 33.94, longitude: -118.41, timeZone: "America/Los_Angeles"),
            to: nil
        )
        let day = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [lax])
        let londonPOI = activityAt(latitude: 51.50, longitude: -0.12)

        XCTAssertNil(ItineraryLocalTime.nearestAirportTimeZone(for: londonPOI, in: [day]))
        XCTAssertNil(ItineraryLocalTime.timeZoneByCardID(in: [day])[londonPOI.id])
    }

    func testNearestAirportTimeZoneRequiresPlaceCoordinate() {
        let haneda = flight(
            from: airportLocation(latitude: 35.55, longitude: 139.78, timeZone: "Asia/Tokyo"),
            to: nil
        )
        let day = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [haneda])
        let unlocated = activityAt(latitude: nil, longitude: nil)

        XCTAssertNil(ItineraryLocalTime.nearestAirportTimeZone(for: unlocated, in: [day]))
    }

    func testRailTimesUsePolicyStringsForHotelsAndEndAtForOthers() {
        let hotel = TravelCardSnapshot(
            dayID: 1,
            kind: .hotel,
            title: "Hotel",
            startAt: .now,
            checkInTime: "15:00",
            checkOutTime: "11:00"
        )
        XCTAssertEqual(ItineraryLocalTime.railStartTime(for: hotel)?.text, "15:00")
        XCTAssertEqual(ItineraryLocalTime.railEndTime(for: hotel)?.text, "11:00")

        let openEnded = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Walk",
            startAt: .now,
            endAt: nil
        )
        XCTAssertNotNil(ItineraryLocalTime.railStartTime(for: openEnded, timeZone: tokyo))
        XCTAssertNil(ItineraryLocalTime.railEndTime(for: openEnded, timeZone: tokyo))
    }

    func testLocalBadgeMarksTimesOutsideDeviceTimeZone() {
        let device = ItineraryLocalTime.deviceTimeZone
        let card = flight(
            from: airportLocation(latitude: 35.55, longitude: 139.78, timeZone: "Asia/Tokyo"),
            to: nil
        )

        // 机票起点固定用机场时区：与设备时区不同时必须标注「当地」。
        XCTAssertEqual(
            ItineraryLocalTime.railStartTime(for: card, timeZone: device)?.showsLocalBadge,
            device.identifier != tokyo.identifier
        )
    }

    func testTimeRangeFormatsInProvidedTimeZone() {
        let startAt = Date(timeIntervalSince1970: 0)
        let card = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Museum",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(90 * 60)
        )
        let formatter = shortTimeFormatter(for: tokyo)
        let expected = String(
            format: String(localized: "itinerary.cardTimeRange"),
            formatter.string(from: startAt),
            formatter.string(from: startAt.addingTimeInterval(90 * 60))
        )

        XCTAssertEqual(ItineraryListPresentation.timeRange(for: card, timeZone: tokyo), expected)
    }
}
