import Foundation
import XCTest
@testable import TravelCompanion

final class MemoTests: XCTestCase {
    func testMemoAssistResultDecodesAlarmsRemindersAndItems() throws {
        let json = """
        {"data":{"alarms":[
            {"title":"赶飞机闹钟","time":"06:30","reason":"8:00 的航班，提前 1.5 小时起床"}
        ],"reminders":[
            {"title":"带护照","notes":"有效期 6 个月以上","dueDate":"2026-10-01","dueTime":"20:00"}
        ],"items":[
            {"name":"护照","category":"证件","notes":null},
            {"name":"日元现金","category":"财务"}
        ]}}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(APIEnvelope<MemoAssistResult>.self, from: json).data
        XCTAssertEqual(result.alarms.count, 1)
        XCTAssertEqual(result.alarms[0].title, "赶飞机闹钟")
        XCTAssertEqual(result.alarms[0].time, "06:30")
        XCTAssertEqual(result.reminders.count, 1)
        XCTAssertEqual(result.reminders[0].dueTime, "20:00")
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items[1].category, "财务")
    }

    func testMemoAssistResultToleratesMissingSections() throws {
        let json = Data("{\"data\":{}}".utf8)
        let result = try JSONDecoder().decode(APIEnvelope<MemoAssistResult>.self, from: json).data
        XCTAssertTrue(result.alarms.isEmpty)
        XCTAssertTrue(result.reminders.isEmpty)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testMemoAssistRequestEncodesItineraryWithISO8601Dates() throws {
        let day = MemoAssistRequest.Day(date: "2026-10-01", cards: [
            MemoAssistRequest.Card(kind: "flight", title: "航班", startAt: Date(timeIntervalSince1970: 0), endAt: nil, place: "羽田", fromAirport: "PVG", toAirport: "HND", notes: nil)
        ])
        let request = MemoAssistRequest(
            itinerary: MemoAssistRequest.Itinerary(destination: "东京", startDate: "2026-10-01", endDate: "2026-10-02", currency: "JPY", days: [day]),
            tomorrowDate: "2026-10-02"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let itinerary = try XCTUnwrap(object["itinerary"] as? [String: Any])
        let cards = try XCTUnwrap(itinerary["days"] as? [[String: Any]]).first?["cards"] as? [[String: Any]]
        let startAt = try XCTUnwrap(cards?.first?["startAt"] as? String)
        XCTAssertTrue(startAt.hasSuffix("T00:00:00Z"), "startAt should be ISO8601 encoded, got \(startAt)")
        XCTAssertEqual(object["tomorrowDate"] as? String, "2026-10-02")
    }
}
