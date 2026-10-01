import Foundation
import XCTest
@testable import PrintGlance

final class BambuSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func reported(at now: Date) -> BambuSnapshot {
        let s = BambuSnapshot(printerID: "x2d", name: "X2D")
        s.ingest(["print": ["gcode_state": "RUNNING"]], now: now)
        return s
    }

    func testConnectionLostKeepsOnlineForGrace() {
        let s = reported(at: t0)
        s.connectionLost(now: t0)
        XCTAssertTrue(s.isOnline(now: t0 + 29))
        XCTAssertFalse(s.isOnline(now: t0 + 31))
    }

    func testSilentLinkGoesOfflineAfterStale() {
        let s = reported(at: t0)
        XCTAssertTrue(s.isOnline(now: t0 + 119))
        XCTAssertFalse(s.isOnline(now: t0 + 121))
    }

    func testReportInsideGraceRestoresStaleWindow() {
        let s = reported(at: t0)
        s.connectionLost(now: t0)
        s.ingest(["print": ["gcode_state": "RUNNING"]], now: t0 + 10)
        XCTAssertTrue(s.isOnline(now: t0 + 129))
        XCTAssertFalse(s.isOnline(now: t0 + 131))
    }

    func testSleptOnlineStaysOnlineForGraceAfterWake() {
        let s = reported(at: t0)
        s.willSleep(now: t0 + 1)
        XCTAssertTrue(s.isOnline(now: t0 + 500))
        s.didWake(now: t0 + 600)
        XCTAssertTrue(s.isOnline(now: t0 + 629))
        XCTAssertFalse(s.isOnline(now: t0 + 631))
    }

    func testOfflineRowKeepsLastReport() {
        let s = BambuSnapshot(printerID: "x2d", name: "X2D")
        s.ingest(["print": ["gcode_state": "RUNNING", "mc_percent": 52, "mc_remaining_time": 84]], now: t0)
        XCTAssertEqual(s.lastReportAt, t0)

        let online = BambuPrint.row(id: "x2d", name: "X2D", printObj: s.printObj, online: true, lastReportAt: t0)
        XCTAssertNil(online.lastSeen, "online rows stay equal between messages")
        XCTAssertNil(online.lastState)

        let offline = BambuPrint.row(id: "x2d", name: "X2D", printObj: s.printObj, online: false, lastReportAt: t0)
        XCTAssertEqual(offline.state, "OFFLINE")
        XCTAssertEqual(offline.lastSeen, t0)
        XCTAssertEqual(offline.lastState, "RUNNING")
        XCTAssertEqual(offline.percent, 52)

        let never = BambuPrint.row(id: "x2d", name: "X2D", printObj: [:], online: false)
        XCTAssertNil(never.lastSeen)
        XCTAssertNil(never.lastState)
    }

    func testSleptOfflineStaysOffline() {
        let s = reported(at: t0)
        s.connectionLost(now: t0)
        s.willSleep(now: t0 + 60)
        s.didWake(now: t0 + 600)
        XCTAssertFalse(s.isOnline(now: t0 + 600))
    }
}
