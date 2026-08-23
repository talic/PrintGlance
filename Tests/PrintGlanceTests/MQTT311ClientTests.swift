import Network
import XCTest
@testable import PrintGlance

final class MQTT311ClientTests: XCTestCase {
    func testReconnectBackoffCapsAt30s() {
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 1), 1)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 2), 2)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 3), 4)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 4), 8)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 5), 16)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 6), 30)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 20), 30)
        XCTAssertEqual(MQTT311Client.reconnectDelaySeconds(attempt: 0), 1)
        XCTAssertEqual(
            MQTT311Client.reconnectDelayNanoseconds(attempt: 1),
            1_000_000_000
        )
    }

    func testFailReasonWaitingRefused() {
        XCTAssertEqual(
            MQTT311Client.failReason(for: .waiting(.posix(.ECONNREFUSED))),
            "ECONNREFUSED"
        )
        XCTAssertEqual(
            MQTT311Client.failReason(for: .failed(.posix(.ECONNREFUSED))),
            "ECONNREFUSED"
        )
        XCTAssertEqual(MQTT311Client.failToken(.posix(.ECONNREFUSED)), "ECONNREFUSED")
        XCTAssertTrue(MQTT311Client.isTerminalWaitError(.posix(.ECONNREFUSED)))
    }

    func testFailReasonWaitingNonRefusedIsNil() {
        XCTAssertNil(MQTT311Client.failReason(for: .waiting(.posix(.EAGAIN))))
        XCTAssertNil(MQTT311Client.failReason(for: .waiting(.posix(.ETIMEDOUT))))
        XCTAssertFalse(MQTT311Client.isTerminalWaitError(.posix(.ETIMEDOUT)))
        XCTAssertFalse(MQTT311Client.isTerminalWaitError(.posix(.EAGAIN)))
    }

    func testRemainingLengthRoundTrip() {
        for n in [0, 1, 127, 128, 16383] {
            let encoded = MQTT311Client.encodeRemainingLength(n)
            var packet = Data([0x10])
            packet.append(encoded)
            packet.append(Data(repeating: 0, count: n))
            let decoded = MQTT311Client.decodeRemainingLength([UInt8](packet), start: 1)
            XCTAssertEqual(decoded?.0, n, "n=\(n)")
        }
    }
}
