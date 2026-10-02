import XCTest
@testable import PrintGlance

/// The Add Printer window, read and driven through accessibility: pick, type, connect, welcome.
@MainActor
final class SetupScreenTests: XCTestCase {
    private let garage = PrinterDiscovery.Hit(ip: "192.0.2.20", serial: "01P00A411800456", name: "Garage P1S", model: "C12")
    private let office = PrinterDiscovery.Hit(ip: "192.0.2.21", serial: "00M09A350100123", name: "Office X1C", model: "BL-P001")
    private let unnamed = PrinterDiscovery.Hit(ip: "192.0.2.22", serial: "0309DA123456789", name: "", model: "N1")
    private let saved = SavedPrinters(
        printers: [PrinterSettings(ip: "192.0.2.21", serial: "00M09A350100123", accessCode: "12345678", name: "Office X1C")],
        focusId: nil
    )

    private func screen(_ flow: SetupFlow) throws -> Screen {
        let s = try Screen(SetupView(flow: flow))
        assertReadsWell(s)
        XCTAssertEqual(s.size.width, 360, "the window keeps its width; text wraps")
        return s
    }

    func testSearchingShowsProgress() throws {
        let f = SetupFlow(mode: .add, saved: saved)
        f.scanning = true
        let s = try screen(f)
        XCTAssertTrue(s.has("Searching…"))
        XCTAssertNil(s.find("Search Again"))
    }

    func testFoundPrintersArePickedAndAddedOnesAreNot() throws {
        let f = SetupFlow(mode: .add, saved: saved)
        f.found = [garage, office, unnamed]
        let s = try screen(f)
        XCTAssertEqual(s.controls.map(\.label), [
            "Search Again",
            "Garage P1S, P1S · 192.0.2.20",
            "Office X1C, X1 Carbon · 192.0.2.21, Added",
            "A1 mini, 192.0.2.22",
            "Enter IP and serial instead",
            "Access code",
            "Name",
            "Cancel",
            "Connect",
        ])
        XCTAssertFalse(try s.control("Office X1C, X1 Carbon · 192.0.2.21, Added").enabled, "picking it would replace the saved one")
        XCTAssertFalse(try s.control("Connect").enabled)

        try s.press("Garage P1S, P1S · 192.0.2.20")
        XCTAssertEqual(f.draft.ip, "192.0.2.20")
        XCTAssertEqual(try s.control("Name").value, "Garage P1S")
        XCTAssertFalse(try s.control("Connect").enabled, "still needs the access code")
    }

    func testTypingTheAccessCodeEnablesConnectAndHintsAtItsLength() throws {
        let f = SetupFlow(mode: .add, saved: saved)
        f.found = [garage]
        let s = try screen(f)
        try s.press("Garage P1S, P1S · 192.0.2.20")
        try s.type("1234", into: "Access code")
        XCTAssertEqual(f.draft.accessCode, "1234")
        XCTAssertTrue(s.has("Access codes are usually 8 characters."))
        XCTAssertTrue(try s.control("Connect").enabled)
        try s.type("12345678", into: "Access code")
        XCTAssertFalse(s.has("Access codes are usually 8 characters."))
    }

    func testNothingFoundShowsTheManualFields() throws {
        let f = SetupFlow(mode: .add, saved: .empty)
        f.manual = true
        let s = try screen(f)
        XCTAssertTrue(s.has("No printers found on this Wi-Fi."))
        for field in ["IP address", "Serial number", "Access code", "Name"] {
            XCTAssertEqual(try s.control(field).role, "AXTextField", field)
        }
    }

    func testConnectingWelcomesAfterThePrinterAnswers() throws {
        let h = ModelHarness(self)
        let f = SetupFlow(mode: .add, saved: h.model.settings, model: h.model, discover: h.network.scan)
        f.manual = true
        var closed = 0
        f.dismiss = { closed += 1 }
        let s = try screen(f)
        try s.type("192.0.2.10", into: "IP address")
        try s.type("20P9AJ5B0700123", into: "Serial number")
        try s.type("a1b2c3d4", into: "Access code")
        try s.type("X2D", into: "Name")
        try s.press("Connect")

        XCTAssertTrue(s.has("Connecting to X2D…"))
        XCTAssertFalse(try s.control("Access code").enabled, "fields lock while it waits")
        XCTAssertFalse(try s.control("Connect").enabled)

        try XCTUnwrap(h.printers.latest("20P9AJ5B0700123")).accept()
        s.settle()
        XCTAssertEqual(s.texts, ["Connected", "PrintGlance is in your menu bar. Click it to see your print."])
        XCTAssertEqual(try s.control("Open at login").value, "1", "starts on")
        try s.press("Open at login") // leave it off: on would register this test runner as a login item
        XCTAssertFalse(f.openAtLogin)
        try s.press("Done")
        XCTAssertEqual(closed, 1)
    }

    func testFailureSaysWhyAndOffersTryAgain() throws {
        let f = SetupFlow(mode: .add, saved: .empty)
        f.manual = true
        f.draft = .x2d()
        f.phase = .failed(SetupFlow.failureMessage("MQTT CONNACK 5", ip: "192.0.2.10"))
        let s = try screen(f)
        XCTAssertTrue(s.has("The access code was rejected. Check it on the printer: Settings, then LAN or Network."))
        XCTAssertTrue(try s.control("Try Again").enabled)
    }

    func testEditOffersRemoveAndSave() throws {
        let f = SetupFlow(mode: .edit(serial: "00M09A350100123"), saved: saved)
        let s = try screen(f)
        XCTAssertEqual(try s.control("IP address").value, "192.0.2.21")
        XCTAssertEqual(try s.control("Access code").value, "12345678")
        XCTAssertTrue(try s.control("Remove…").enabled)
        XCTAssertTrue(try s.control("Save").enabled)
        XCTAssertNil(s.find("Connect"))
    }

    func testCancelCloses() throws {
        let f = SetupFlow(mode: .add, saved: .empty)
        var closed = 0
        f.dismiss = { closed += 1 }
        try screen(f).press("Cancel")
        XCTAssertEqual(closed, 1)
    }

    func testWelcomeExplainsLoginItemApproval() throws {
        let f = SetupFlow(mode: .add, saved: .empty)
        f.phase = .welcome
        f.loginNeedsApproval = true
        let s = try screen(f)
        XCTAssertTrue(s.has("Allow PrintGlance in System Settings > General > Login Items."))
        XCTAssertNotNil(s.find("Open System Settings"))
        XCTAssertFalse(try s.control("Open at login").enabled)
    }
}
