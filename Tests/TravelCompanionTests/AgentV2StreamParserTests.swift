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

    func testStreamRetryPolicyRetriesTransientFailuresAndLocalizesExhaustion() {
        XCTAssertTrue(AgentV2StreamRetryPolicy.shouldRetry(AgentV2IncompleteStreamError()))
        XCTAssertTrue(AgentV2StreamRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(AgentV2StreamRetryPolicy.shouldRetry(APIResponseError(statusCode: 502)))
        XCTAssertFalse(AgentV2StreamRetryPolicy.shouldRetry(URLError(.badURL)))
        XCTAssertFalse(AgentV2StreamRetryPolicy.shouldRetry(APIResponseError(statusCode: 400)))

        let message = AgentV2StreamRetryPolicy.userMessage(for: URLError(.networkConnectionLost))
        XCTAssertTrue(message.contains("网络连接不稳定"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("connection lost"))
    }

    func testUnscheduledCandidateWithNullScheduleDoesNotAbortStream() throws {
        // 纯 POI 询问卡的 date/startAt 为 null：必须解码为未排期候选而不是
        // 让整条流在 candidate_upsert 处中断。
        let candidateID = UUID().uuidString.lowercased()
        let fixture = """
        event: candidate_upsert
        data: {"id":"\(candidateID)","kind":"activity","title":"热带植物园","images":["https://img.example/one.jpg","https://img.example/two.jpg"],"date":null,"startAt":null,"endAt":null,"place":null,"placeStatus":"failed","allowsUnverifiedPlace":true,"tips":[],"risks":[],"missingFields":["地图地点待确认"],"selected":false}

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var candidate: AgentV2Candidate?
        var sawDone = false
        for byte in fixture.utf8 {
            guard let event = try parser.consume(byte) else { continue }
            if case .candidateUpsert(let value) = event { candidate = value }
            if case .done = event { sawDone = true }
        }

        let decoded = try XCTUnwrap(candidate)
        XCTAssertEqual(decoded.date, "")
        XCTAssertEqual(decoded.startAt, "")
        XCTAssertEqual(decoded.images, ["https://img.example/one.jpg", "https://img.example/two.jpg"])
        XCTAssertTrue(decoded.hasAllowedUnverifiedPlace)
        XCTAssertFalse(decoded.isCommitReady, "未排期候选需先由后续轮次排期才可提交")
        XCTAssertTrue(sawDone)
    }

    func testOutOfRangeCandidateStaysDecodedButCannotCommit() throws {
        let candidateID = UUID().uuidString.lowercased()
        let fixture = """
        event: candidate_upsert
        data: {"id":"\(candidateID)","kind":"flight","title":"CA123","date":"2026-10-05","dateStatus":"outOfRange","startAt":"09:00","endAt":"12:00","place":null,"placeStatus":"notRequired","bookingCode":"CA123","fromAirport":"PEK","toAirport":"HND","tips":[],"risks":[],"missingFields":["日期超出行程范围"],"selected":false}

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var candidate: AgentV2Candidate?
        for byte in fixture.utf8 {
            guard let event = try parser.consume(byte) else { continue }
            if case .candidateUpsert(let value) = event { candidate = value }
        }

        let decoded = try XCTUnwrap(candidate)
        XCTAssertEqual(decoded.dateStatus, .outOfRange)
        XCTAssertEqual(decoded.date, "2026-10-05")
        XCTAssertFalse(decoded.isCommitReady)
    }

    func testFlightScheduleAndMultipleSourcesSurviveCandidateStreamDecoding() throws {
        let candidateID = UUID().uuidString.lowercased()
        let fixture = """
        event: candidate_upsert
        data: {"id":"\(candidateID)","kind":"flight","title":"ID6331 努拉莱伊至科莫多","date":"2026-09-26","dateStatus":"inRange","startAt":"11:45","endAt":"13:00","place":null,"placeStatus":"notRequired","bookingCode":"ID6331","fromAirport":"DPS","toAirport":"LBJ","sources":[{"provider":"xiaohongshu","url":"https://www.xiaohongshu.com/explore/one","title":"科莫多交通攻略","author":"旅行者甲","sourceProof":"proof-one"},{"provider":"xiaohongshu","url":"https://www.xiaohongshu.com/explore/two","title":"巴厘岛转机记录","author":"旅行者乙","sourceProof":"proof-two"}],"tips":[],"risks":[],"missingFields":[],"selected":false}

        event: done
        data: {}


        """
        var parser = AgentV2SSEParser()
        var candidate: AgentV2Candidate?
        for byte in fixture.utf8 {
            guard let event = try parser.consume(byte) else { continue }
            if case .candidateUpsert(let value) = event { candidate = value }
        }

        let decoded = try XCTUnwrap(candidate)
        XCTAssertEqual(decoded.startAt, "11:45")
        XCTAssertEqual(decoded.endAt, "13:00")
        XCTAssertEqual(decoded.bookingCode, "ID6331")
        XCTAssertEqual(decoded.sources.map(\.url), [
            "https://www.xiaohongshu.com/explore/one",
            "https://www.xiaohongshu.com/explore/two",
        ])
        XCTAssertTrue(decoded.isCommitReady)
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

    func testLiveCardRecognizesFlightKindFromStreamedField() {
        var card = AgentV2LiveCard(id: UUID(), index: 0)

        card.fields["kind"] = " flight "

        XCTAssertEqual(card.kind, .flight)
    }
}
