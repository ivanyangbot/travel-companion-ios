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
}
