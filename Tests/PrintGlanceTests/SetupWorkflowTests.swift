import XCTest
@testable import PrintGlance

/// The Add Printer / Edit window's flow against a real `GlanceModel` and a fake printer: search, pick,
/// connect, fail, retry, cancel. `SetupFlowTests` covers the pure helpers.
@MainActor
final class SetupWorkflowTests: XCTestCase {
    private let x2d = PrinterSettings.x2d()
    private let p1s = PrinterSettings.p1s()
    private let garage = PrinterDiscovery.Hit(ip: "192.0.2.20", serial: "01P00A411800456", name: "Garage P1S", model: "C12")
    private let office = PrinterDiscovery.Hit(ip: "192.0.2.21", serial: "00M09A350100123", name: "Office X1C", model: "BL-P001")
    private let unnamed = PrinterDiscovery.Hit(ip: "192.0.2.22", serial: "0309DA123456789", name: "", model: "N1")

    private func flow(_ h: ModelHarness, _ mode: SetupWindow.Mode = .add) -> SetupFlow {
        SetupFlow(mode: mode, saved: h.model.settings, model: h.model, discover: h.network.scan)
    }

    // MARK: - Finding the printer

    func testSearchListsPrintersOnTheWiFi() async {
        let h = ModelHarness(self)
        h.network.hits = [garage, office]
        let f = flow(h)
        f.scan()
        XCTAssertTrue(f.scanning)
        let done = await eventually { !f.scanning }
        XCTAssertTrue(done)
        XCTAssertEqual(f.found, [garage, office])
        XCTAssertFalse(f.manual, "found something, so the IP fields stay folded")
    }

    func testFindingNothingOpensManualEntry() async {
        let h = ModelHarness(self)
        let f = flow(h)
        f.scan()
        let done = await eventually { !f.scanning }
        XCTAssertTrue(done)
        XCTAssertTrue(f.found.isEmpty)
        XCTAssertTrue(f.manual)
    }

    func testPickingFillsTheAddressAndSuggestsAName() {
        let f = flow(ModelHarness(self))
        f.found = [garage, office, unnamed]
        f.pick(garage)
        XCTAssertEqual(f.draft.ip, "192.0.2.20")
        XCTAssertEqual(f.draft.serial, "01P00A411800456")
        XCTAssertEqual(f.draft.name, "Garage P1S")
        XCTAssertTrue(f.isSelected(garage))
        f.pick(unnamed)
        XCTAssertEqual(f.draft.name, "A1 mini", "a suggested name follows the pick")
        f.draft.name = "Kitchen"
        f.pick(office)
        XCTAssertEqual(f.draft.name, "Kitchen", "a typed name stays")
    }

    // MARK: - Connecting

    func testFirstPrinterConnectsAndWelcomes() throws {
        let h = ModelHarness(self)
        let f = flow(h)
        f.draft = x2d
        f.connect()
        XCTAssertEqual(f.phase, .connecting)
        XCTAssertEqual(h.model.settings.printers, [x2d], "saved before the wait, so the link can dial")
        try XCTUnwrap(h.printers.latest(x2d.serial)).accept()
        XCTAssertEqual(f.phase, .welcome)
    }

    func testAnotherPrinterConnectsAndTheWindowCloses() async throws {
        let h = ModelHarness(self)
        h.add(x2d)
        let f = flow(h)
        let closed = Counter()
        f.dismiss = { closed.count += 1 }
        f.draft = p1s
        f.connect()
        try XCTUnwrap(h.printers.latest(p1s.serial)).accept()
        XCTAssertEqual(f.phase, .connected)
        let gone = await eventually { closed.count == 1 }
        XCTAssertTrue(gone, "closes a second after Connected")
        XCTAssertEqual(h.model.settings.printers.map(\.serial), [x2d.serial, p1s.serial])
    }

    func testRejectedCodeSaysSoAndTryAgainReplacesTheAttempt() throws {
        let h = ModelHarness(self)
        let f = flow(h)
        f.draft = x2d
        f.draft.accessCode = "wrong123"
        f.connect()
        try XCTUnwrap(h.printers.latest(x2d.serial)).drop("MQTT CONNACK 5")
        XCTAssertEqual(f.phase, .failed("The access code was rejected. Check it on the printer: Settings, then LAN or Network."))

        f.draft.accessCode = "a1b2c3d4"
        f.connect()
        XCTAssertEqual(f.phase, .connecting)
        XCTAssertEqual(h.model.settings.printers, [x2d], "the retry replaces the first attempt, never adds a second row")
        let link = try XCTUnwrap(h.printers.latest(x2d.serial))
        XCTAssertEqual(link.dials.last?.password, "a1b2c3d4")
        link.accept()
        XCTAssertEqual(f.phase, .welcome)
    }

    func testSilentPrinterFailsWithNoAnswer() async throws {
        let h = ModelHarness(self, connectTimeout: .milliseconds(50))
        let f = flow(h)
        f.draft = x2d
        f.connect()
        let failed = await eventually { f.phase != .connecting }
        XCTAssertTrue(failed)
        XCTAssertEqual(f.phase, .failed("No answer from 192.0.2.10. Check that the printer is on and on the same Wi-Fi as this Mac."))
    }

    func testRefusedConnectionPointsAtTheIP() throws {
        let h = ModelHarness(self)
        let f = flow(h)
        f.draft = x2d
        f.connect()
        try XCTUnwrap(h.printers.latest(x2d.serial)).drop("ECONNREFUSED")
        XCTAssertEqual(f.phase, .failed(GlanceCopy.feedDownDetail(reason: "ECONNREFUSED")))
    }

    func testLateSuccessAfterAFailureStillCounts() throws {
        let h = ModelHarness(self)
        let f = flow(h)
        f.draft = x2d
        f.connect()
        let link = try XCTUnwrap(h.printers.latest(x2d.serial))
        link.drop("closed")
        guard case .failed = f.phase else { return XCTFail("\(f.phase)") }
        // Rediscovery found it at a new IP, or the retry got through.
        link.accept()
        XCTAssertEqual(f.phase, .welcome)
    }

    // MARK: - Leaving

    func testCancelWhileConnectingPutsThePrintersBack() throws {
        let h = ModelHarness(self)
        h.add(x2d)
        let f = flow(h)
        f.draft = p1s
        f.connect()
        let attempt = try XCTUnwrap(h.printers.latest(p1s.serial))
        f.cancel()
        XCTAssertEqual(h.model.settings.printers, [x2d])
        XCTAssertEqual(attempt.disconnects, 1)
        XCTAssertEqual(SavedPrinters.load(from: h.defaults).printers, [x2d])
    }

    func testCancelBeforeConnectChangesNothing() {
        let h = ModelHarness(self)
        h.add(x2d)
        let clients = h.printers.clients.count
        let f = flow(h)
        f.draft = p1s
        f.cancel()
        XCTAssertEqual(h.model.settings.printers, [x2d])
        XCTAssertEqual(h.printers.clients.count, clients, "no reconnect")
    }

    func testCancelAfterConnectedKeepsThePrinter() throws {
        let h = ModelHarness(self)
        h.add(x2d)
        let f = flow(h)
        f.draft = p1s
        f.connect()
        try XCTUnwrap(h.printers.latest(p1s.serial)).accept()
        f.cancel()
        XCTAssertEqual(h.model.settings.printers.count, 2)
    }

    func testDoneOnWelcomeAsksForNotifications() async {
        let h = ModelHarness(self)
        let f = flow(h)
        var closed = 0
        f.dismiss = { closed += 1 }
        f.phase = .welcome
        f.openAtLogin = false // true would register this test runner as a login item
        f.finish()
        XCTAssertEqual(closed, 1)
        let asked = await eventually { h.notifications.permissionRequests == 1 }
        XCTAssertTrue(asked)
    }

    func testClosingTheWelcomeStillAsksForNotifications() async {
        let h = ModelHarness(self)
        let f = flow(h)
        var closed = 0
        f.dismiss = { closed += 1 }
        f.phase = .welcome
        f.openAtLogin = false
        f.cancel()
        XCTAssertEqual(closed, 0, "the window is already closing")
        let asked = await eventually { h.notifications.permissionRequests == 1 }
        XCTAssertTrue(asked)
    }

    // MARK: - Editing

    func testEditStartsFromTheSavedPrinterWithFieldsOpen() {
        let h = ModelHarness(self)
        h.add(x2d, p1s)
        let f = flow(h, .edit(serial: p1s.serial))
        XCTAssertEqual(f.draft, p1s)
        XCTAssertTrue(f.manual)
        XCTAssertEqual(f.title, "Edit P1S")
        XCTAssertEqual(flow(h).title, "Add Printer")
    }

    func testEditingTheIPReplacesThatRow() throws {
        let h = ModelHarness(self)
        h.add(x2d, p1s)
        h.model.focusPrinter(p1s.serial)
        let f = flow(h, .edit(serial: p1s.serial))
        f.draft.ip = " 192.0.2.50 "
        f.connect()
        XCTAssertEqual(h.model.settings.printers.map(\.ip), ["192.0.2.10", "192.0.2.50"])
        XCTAssertEqual(h.model.settings.focusId, p1s.serial)
        try XCTUnwrap(h.printers.latest(p1s.serial)).accept()
        XCTAssertEqual(f.phase, .connected)
    }

    func testEditingPausesRediscoveryUntilTheWindowCloses() async throws {
        let paused = ModelHarness(self)
        let link = try XCTUnwrap(paused.add(x2d).first)
        _ = flow(paused, .edit(serial: x2d.serial))
        paused.network.hits = [PrinterDiscovery.Hit(ip: "192.0.2.99", serial: x2d.serial, name: "", model: "")]
        link.drop("closed")
        let searched = await eventually { paused.network.scans == 1 }
        XCTAssertTrue(searched)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(link.dials.map(\.host), ["192.0.2.10"], "the window owns the IP while open")

        let resumed = ModelHarness(self)
        let other = try XCTUnwrap(resumed.add(x2d).first)
        flow(resumed, .edit(serial: x2d.serial)).didClose()
        resumed.network.hits = paused.network.hits
        other.drop("closed")
        let adopted = await eventually { other.dials.last?.host == "192.0.2.99" }
        XCTAssertTrue(adopted)
    }
}
