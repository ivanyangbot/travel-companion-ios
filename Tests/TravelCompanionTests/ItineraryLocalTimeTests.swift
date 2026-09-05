import Foundation
import XCTest
import SwiftData
@testable import TravelCompanion

/// 「当地时间」换算口径：机票起降用机场时区、酒店/景点近似用最近的带时区
/// 机场、都没有时退回设备时区。格式化输出依赖系统语言，断言全部对照同配置
/// 的本地 DateFormatter，不写死字面量。
final class ItineraryLocalTimeTests: XCTestCase {
    @MainActor
    func testManualDurationPersistsSeparatelyAndSurvivesRouteRefresh() throws {
        let container = try ModelContainer(for: CardLegPreference.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CardLegStore(modelContext: container.mainContext)
        try store.setManualDuration(1800, routeKey: "driving-coordinates", for: "a-b")
        try store.setManualDuration(3600, routeKey: "walking-coordinates", for: "a-b")
        store.clearAllEstimateFailures()
        let reloaded = CardLegStore(modelContext: ModelContext(container))
        XCTAssertEqual(reloaded.manualDuration(routeKey: "driving-coordinates", for: "a-b"), 1800)
        XCTAssertEqual(reloaded.manualDuration(routeKey: "walking-coordinates", for: "a-b"), 3600)
        XCTAssertNil(reloaded.manualDuration(routeKey: "driving-new-coordinates", for: "a-b"))
        XCTAssertNil(reloaded.manualDuration(routeKey: "driving-coordinates", for: "b-a"))
        try store.setManualDuration(nil, routeKey: "driving-coordinates", for: "a-b")
        XCTAssertNil(store.manualDuration(routeKey: "driving-coordinates", for: "a-b"))
        XCTAssertEqual(store.manualDuration(routeKey: "walking-coordinates", for: "a-b"), 3600)
    }
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
        let shibuya = activityAt(latitude: 35.66, longitude: 139.70)
        let day = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [haneda, lax, shibuya])

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

    func testTimeZoneByCardIDPrefersServerPlaceTimeZone() {
        // 行程里只有洛杉矶机场，但景点 place 带服务端解析的东京时区：
        // 应直接采用 place 时区，而不是机场近似。
        let lax = flight(
            from: airportLocation(latitude: 33.94, longitude: -118.41, timeZone: "America/Los_Angeles"),
            to: nil
        )
        let tokyoPOI = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Shibuya",
            startAt: .now,
            place: PlaceSnapshot(
                id: 1,
                name: "Shibuya Crossing",
                address: nil,
                latitude: 35.66,
                longitude: 139.70,
                placeId: nil,
                cityCode: nil,
                timeZone: "Asia/Tokyo",
                businessHours: nil,
                updatedAt: .now
            )
        )
        let day = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [lax, tokyoPOI])

        XCTAssertEqual(ItineraryLocalTime.timeZoneByCardID(in: [day])[tokyoPOI.id], tokyo)
        // 没有服务端时区的卡仍走机场近似/无坐标兜底。
        XCTAssertNil(ItineraryLocalTime.placeTimeZone(for: activityAt(latitude: 35.66, longitude: 139.70)))
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

    func testHotelRailStartFallsBackToActualStartWhenPolicyTimeIsMissing() {
        let hotel = TravelCardSnapshot(
            dayID: 1,
            kind: .hotel,
            title: "CAESAR",
            startAt: utcDate(17, 0)
        )

        let result = ItineraryLocalTime.railStartTime(
            for: hotel,
            timeZone: utc,
            displayedDay: "2026-09-04"
        )

        XCTAssertEqual(result?.text, "17:00")
        XCTAssertNil(result?.dateText)
    }

    // MARK: 轨道时间固定 24 小时制

    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ hour: Int, _ minute: Int) -> Date {
        utcCalendar.date(
            from: DateComponents(year: 2026, month: 9, day: 4, hour: hour, minute: minute)
        )!
    }

    func testRailTimeTextUses24HourFormat() {
        XCTAssertEqual(ItineraryLocalTime.railTimeText(utcDate(15, 5), in: utc), "15:05")
        XCTAssertEqual(ItineraryLocalTime.railTimeText(utcDate(9, 30), in: utc), "09:30")
        XCTAssertEqual(ItineraryLocalTime.railTimeText(utcDate(0, 0), in: utc), "00:00")
    }

    // MARK: 交通衔接独立于计划时间

    func testRailEndTimeAccountsForTransitToNextCard() {
        let card = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Museum",
            startAt: utcDate(10, 0),
            endAt: utcDate(11, 0)
        )
        let next = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Lunch",
            startAt: utcDate(11, 30)
        )

        // 无交通耗时：保持原结束时刻。
        XCTAssertEqual(ItineraryLocalTime.railEndTime(for: card, timeZone: utc)?.text, "11:00")
        // 即使交通需要提前出发，也不能篡改活动的计划结束时刻。
        XCTAssertEqual(
            ItineraryLocalTime.railEndTime(for: card, nextCard: next, transitSeconds: 45 * 60, timeZone: utc)?.text,
            "11:00"
        )
        // 无结束时刻不虚构时间。
        let openCard = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Walk",
            startAt: utcDate(10, 0)
        )
        XCTAssertNil(ItineraryLocalTime.railEndTime(for: openCard, nextCard: next, transitSeconds: 45 * 60, timeZone: utc))
        // 即使完全赶不上，仍保留计划结束时刻，由交通行解释冲突。
        XCTAssertEqual(ItineraryLocalTime.railEndTime(for: card, nextCard: next, transitSeconds: 2 * 3600, timeZone: utc)?.text, "11:00")
    }

    func testScreenshotConflictPreservesNineAMAndReports144MinutesShort() {
        let card = TravelCardSnapshot(dayID: 1, kind: .activity, title: "Padar",
                                      startAt: utcDate(6, 0), endAt: utcDate(9, 0))
        let next = TravelCardSnapshot(dayID: 1, kind: .activity, title: "Komodo", startAt: utcDate(9, 30))
        XCTAssertEqual(ItineraryLocalTime.railEndTime(for: card, nextCard: next, transitSeconds: 174 * 60, timeZone: utc)?.text, "09:00")
        let arrival = ItineraryConnectionTiming.arrival(origin: card, duration: 174 * 60)!
        XCTAssertEqual(arrival, utcDate(11, 54))
        XCTAssertEqual(ItineraryConnectionTiming.shortageMinutes(arrival: arrival, destination: next), 144)
        XCTAssertNil(ItineraryConnectionTiming.shortageMinutes(arrival: next.startAt, destination: next))
        XCTAssertNil(ItineraryConnectionTiming.arrival(origin: card, duration: -1))
    }

    func testOvernightEndIncludesItsDateAndRejectsInvalidEnd() {
        let start = utcDate(23, 30)
        let card = TravelCardSnapshot(dayID: 1, kind: .activity, title: "Overnight",
                                      startAt: start, endAt: start.addingTimeInterval(7200))
        let result = ItineraryLocalTime.railEndTime(for: card, timeZone: utc)
        XCTAssertEqual(result?.text, "01:30")
        XCTAssertNotEqual(result?.dateText, ItineraryLocalTime.railStartTime(for: card, timeZone: utc)?.dateText)
        let invalid = TravelCardSnapshot(dayID: 1, kind: .activity, title: "Invalid", startAt: start, endAt: start.addingTimeInterval(-60))
        XCTAssertNil(ItineraryLocalTime.railEndTime(for: invalid, timeZone: utc))
        XCTAssertNil(ItineraryConnectionTiming.arrival(origin: invalid, duration: 600))
    }

    func testRailDateAppearsOnlyOutsideDisplayedItineraryDay() {
        let sameDay = utcDate(9, 30)
        XCTAssertNil(
            ItineraryLocalTime.dateTextIfOutsideDisplayedDay(
                sameDay,
                displayedDay: "2026-09-04",
                in: utc
            )
        )
        XCTAssertNotNil(
            ItineraryLocalTime.dateTextIfOutsideDisplayedDay(
                sameDay.addingTimeInterval(24 * 3600),
                displayedDay: "2026-09-04",
                in: utc
            )
        )

        let card = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "Activity",
            startAt: sameDay,
            endAt: sameDay.addingTimeInterval(3600)
        )
        XCTAssertNil(
            ItineraryLocalTime.railStartTime(
                for: card,
                timeZone: utc,
                displayedDay: "2026-09-04"
            )?.dateText
        )
        XCTAssertNil(
            ItineraryLocalTime.railEndTime(
                for: card,
                timeZone: utc,
                displayedDay: "2026-09-04"
            )?.dateText
        )
    }

    func testConnectionUsesAbsoluteInstantsAcrossDSTAndAirportTimeZones() {
        let parser = ISO8601DateFormatter()
        let start = parser.date(from: "2026-11-01T00:30:00-07:00")!
        let end = parser.date(from: "2026-11-01T01:30:00-07:00")!
        let nextStart = parser.date(from: "2026-11-01T01:30:00-08:00")!
        let origin = TravelCardSnapshot(dayID: 1, kind: .flight, title: "Flight", startAt: start, endAt: end)
        let next = TravelCardSnapshot(dayID: 1, kind: .activity, title: "Visit", startAt: nextStart)
        let arrival = ItineraryConnectionTiming.arrival(origin: origin, duration: 3600)!
        XCTAssertEqual(arrival, nextStart)
        XCTAssertNil(ItineraryConnectionTiming.shortageMinutes(arrival: arrival, destination: next))
        XCTAssertEqual(ItineraryConnectionTiming.shortageMinutes(arrival: arrival.addingTimeInterval(1), destination: next), 1)
        let hotel = TravelCardSnapshot(dayID: 1, kind: .hotel, title: "Hotel", startAt: start, endAt: end)
        XCTAssertNil(ItineraryConnectionTiming.arrival(origin: hotel, duration: 600))
        XCTAssertNil(ItineraryConnectionTiming.shortageMinutes(arrival: arrival, destination: hotel))
    }

    func testDayStartLegConnectsPreviousNightHotelToFirstLocatedActivity() {
        let hotel = TravelCardSnapshot(
            dayID: 1,
            kind: .hotel,
            title: "Hotel",
            startAt: utcDate(15, 0),
            endAt: utcDate(11, 0).addingTimeInterval(24 * 3600),
            place: PlaceSnapshot(
                id: 1, name: "Hotel", address: nil, latitude: -6.1, longitude: 106.8,
                placeId: nil, cityCode: nil, businessHours: nil, updatedAt: .now
            )
        )
        let activity = TravelCardSnapshot(
            dayID: 2,
            kind: .activity,
            title: "Museum",
            startAt: utcDate(9, 0).addingTimeInterval(24 * 3600),
            place: PlaceSnapshot(
                id: 2, name: "Museum", address: nil, latitude: -6.2, longitude: 106.8,
                placeId: nil, cityCode: nil, businessHours: nil, updatedAt: .now
            )
        )
        let previous = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [hotel])
        let target = TripDaySnapshot(date: "2026-09-05", position: 1, cards: [activity])

        let leg = ItineraryListPresentation.dayStartHotelLeg(for: target, in: [previous, target], timeZone: utc)
        XCTAssertEqual(leg?.hotel.id, hotel.id)
        XCTAssertEqual(leg?.destination.id, activity.id)
    }

    func testDayStartLegSupportsMultiNightHotelAndRejectsMissingPreviousDay() {
        let hotel = TravelCardSnapshot(
            dayID: 1,
            kind: .hotel,
            title: "Hotel",
            startAt: utcDate(15, 0),
            endAt: utcDate(11, 0).addingTimeInterval(2 * 24 * 3600),
            place: PlaceSnapshot(
                id: 1, name: "Hotel", address: nil, latitude: 35.6, longitude: 139.7,
                placeId: nil, cityCode: nil, businessHours: nil, updatedAt: .now
            )
        )
        let activity = activityAt(latitude: 35.7, longitude: 139.8)
        let first = TripDaySnapshot(date: "2026-09-04", position: 0, cards: [hotel])
        let middle = TripDaySnapshot(date: "2026-09-05", position: 1, cards: [])
        let target = TripDaySnapshot(date: "2026-09-06", position: 2, cards: [activity])

        XCTAssertEqual(
            ItineraryListPresentation.dayStartHotelLeg(
                for: target, in: [first, middle, target], timeZone: utc
            )?.hotel.id,
            hotel.id
        )
        XCTAssertNil(
            ItineraryListPresentation.dayStartHotelLeg(
                for: target, in: [first, target], timeZone: utc
            )
        )
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
