import XCTest
@testable import TravelCompanion

final class AgentV2StreamParserTests: XCTestCase {
    func testCompleteFixtureEmitsEventsAndAcceptsEOFOnlyAfterDone() throws {
        let fixture = """
        event: status
        data: "正在规划"

        event: assistant_delta
        data: "先安排已核验地点。"

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var eventKinds: [String] = []

        for byte in fixture.utf8 {
            guard let event = try parser.consume(byte) else { continue }
            switch event {
            case .status: eventKinds.append("status")
            case .assistantDelta: eventKinds.append("assistant_delta")
            case .done: eventKinds.append("done")
            default: eventKinds.append("other")
            }
        }

        XCTAssertEqual(eventKinds, ["status", "assistant_delta", "done"])
        XCTAssertTrue(parser.receivedDone)
        XCTAssertNoThrow(try parser.finishAtEOF())
    }

    func testEOFFixtureWithoutDoneThrowsRetryableLocalizedError() throws {
        let fixture = """
        event: status
        data: "正在核验地点"

        event: assistant_delta
        data: "已经找到第一处地点"


        """
        var parser = AgentV2SSEParser()
        for byte in fixture.utf8 { _ = try parser.consume(byte) }

        XCTAssertFalse(parser.receivedDone)
        XCTAssertThrowsError(try parser.finishAtEOF()) { error in
            XCTAssertEqual(error as? AgentV2IncompleteStreamError, AgentV2IncompleteStreamError())
            XCTAssertTrue(error.localizedDescription.contains("连接中断"))
            XCTAssertTrue(error.localizedDescription.contains("请重试"))
        }
    }

    func testFliggyEventsDecodeAsPairedStructuredSignals() throws {
        // Mirrors the backend's observed ordering: flight start → hotel start
        // (term picked from `origin`) → two completions → done.
        let fixture = """
        event: fliggy_search_started
        data: {"searchType":"flight","origin":"北京"}

        event: fliggy_search_started
        data: {"searchType":"hotel","query":"","destName":"  ","cityName":"上海"}

        event: fliggy_search_completed
        data: {"searchType":"flight","ok":true,"count":8}

        event: fliggy_search_completed
        data: {"searchType":"hotel","ok":false}

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var decoded: [AgentV2StreamEvent] = []
        for byte in fixture.utf8 {
            if let event = try parser.consume(byte) { decoded.append(event) }
        }

        guard decoded.count == 5 else { return XCTFail("expected 5 events, got \(decoded)") }
        guard case .fliggySearchStarted(let flightStart) = decoded[0] else { return XCTFail("expected flight start") }
        XCTAssertEqual(flightStart.searchType, "flight")
        XCTAssertEqual(flightStart.searchTerm, "北京")
        XCTAssertEqual(AgentV2FliggySearchKind(raw: flightStart.searchType), .flight)

        guard case .fliggySearchStarted(let hotelStart) = decoded[1] else { return XCTFail("expected hotel start") }
        // Blank/whitespace terms are skipped; the first valid one wins.
        XCTAssertEqual(hotelStart.searchTerm, "上海")

        guard case .fliggySearchCompleted(let flightDone) = decoded[2] else { return XCTFail("expected flight completion") }
        XCTAssertTrue(flightDone.ok)
        XCTAssertEqual(flightDone.count, 8)

        guard case .fliggySearchCompleted(let hotelDone) = decoded[3] else { return XCTFail("expected hotel completion") }
        XCTAssertFalse(hotelDone.ok)
        XCTAssertNil(hotelDone.count)

        guard case .done = decoded[4] else { return XCTFail("expected done") }
        XCTAssertNoThrow(try parser.finishAtEOF())
    }

    func testUnknownEventNamesAreIgnoredWithoutBreakingTheStream() throws {
        let fixture = """
        event: some_future_event
        data: {"anything":true}

        event: status
        data: "正在规划"

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var events: [AgentV2StreamEvent] = []
        for byte in fixture.utf8 {
            if let event = try parser.consume(byte) { events.append(event) }
        }

        XCTAssertEqual(events.count, 2)
        guard case .status = events[0], case .done = events[1] else { return XCTFail("unexpected events \(events)") }
        XCTAssertNoThrow(try parser.finishAtEOF())
    }
}
