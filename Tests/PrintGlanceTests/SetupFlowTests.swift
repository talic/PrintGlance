import XCTest
@testable import PrintGlance

final class SetupFlowTests: XCTestCase {
    func testSavedPrintersShowAsAddedIgnoringCase() {
        let saved = SavedPrinters(
            printers: [
                PrinterSettings(ip: "192.0.2.10", serial: "01P00A123456789", accessCode: "12345678", name: "A"),
                PrinterSettings(ip: "192.0.2.11", serial: "HALFDONE", accessCode: "", name: "B"),
            ],
            focusId: nil
        )
        let a = hit("01p00a123456789 ")
        XCTAssertTrue(SetupFlow.isAdded(a, saved: saved, editing: nil))
        XCTAssertFalse(SetupFlow.isAdded(a, saved: saved, editing: "01P00A123456789"), "the printer being edited stays pickable")
        XCTAssertTrue(SetupFlow.isAdded(a, saved: saved, editing: "OTHER"))
        XCTAssertFalse(SetupFlow.isAdded(hit("NEW"), saved: saved, editing: nil))
        XCTAssertFalse(SetupFlow.isAdded(hit(""), saved: saved, editing: nil), "no serial, nothing to match")
        XCTAssertFalse(SetupFlow.isAdded(hit("halfdone"), saved: saved, editing: nil), "a half-entered printer can be finished from the list")
    }

    func testAccessCodeHint() {
        XCTAssertNil(SetupFlow.codeHint(""))
        XCTAssertNil(SetupFlow.codeHint("12345678"))
        XCTAssertNil(SetupFlow.codeHint(" AB12cd34 "), "trimmed before counting")
        XCTAssertEqual(SetupFlow.codeHint("1234"), "Access codes are usually 8 characters.")
        XCTAssertEqual(SetupFlow.codeHint("123456789"), "Access codes are usually 8 characters.")
    }

    func testConnectResultFromLinkStatus() {
        let ip = "192.0.2.10"
        XCTAssertEqual(SetupFlow.connectResult(nil, ip: ip), .waiting)
        XCTAssertEqual(SetupFlow.connectResult(.connecting, ip: ip), .waiting)
        XCTAssertEqual(SetupFlow.connectResult(.connected, ip: ip), .connected)
        XCTAssertEqual(
            SetupFlow.connectResult(.failed(reason: "MQTT CONNACK 5"), ip: ip),
            .failed("The access code was rejected. Check it on the printer: Settings, then LAN or Network.")
        )
        XCTAssertEqual(
            SetupFlow.connectResult(.failed(reason: "ECONNREFUSED"), ip: ip),
            .failed(GlanceCopy.feedDownDetail(reason: "ECONNREFUSED"))
        )
        let noAnswer = "No answer from 192.0.2.10. Check that the printer is on and on the same Wi-Fi as this Mac."
        XCTAssertEqual(SetupFlow.connectResult(.failed(reason: "connect timed out"), ip: ip), .failed(noAnswer))
        XCTAssertEqual(SetupFlow.connectResult(.failed(reason: nil), ip: ip), .failed(noAnswer))
        XCTAssertEqual(SetupFlow.failureMessage(nil, ip: ip), noAnswer, "the 20-second wait ends with the same text")
    }

    private func hit(_ serial: String) -> PrinterDiscovery.Hit {
        PrinterDiscovery.Hit(ip: "192.0.2.20", serial: serial, name: "", model: "")
    }
}
