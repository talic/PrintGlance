import XCTest
@testable import PrintGlance

/// The iPhone app and widget: one look at the printer, the shared status, and what the widget says.
@MainActor
final class PhoneGlanceTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }

    /// Saturday 2026-08-22 14:02 GMT.
    private let fetched = Date(timeIntervalSince1970: 1_787_407_320)
    private let pushall = #"{"pushing":{"command":"pushall","sequence_id":"0"}}"#

    // MARK: One look

    private func fetching(
        _ settings: PrinterSettings = .x2d(),
        timeout: Duration = .seconds(8)
    ) async -> (FakeMQTT, Task<PrinterFetch.Outcome, Never>) {
        let client = FakeMQTT()
        let task = Task { await PrinterFetch.fetch(settings, client: client, timeout: timeout) }
        let dialed = await eventually { !client.dials.isEmpty }
        XCTAssertTrue(dialed, "the fetch dials the printer")
        return (client, task)
    }

    func testOneLookAsksForAFullReportAndHangsUp() async {
        let (client, task) = await fetching()
        XCTAssertEqual(client.dials.first?.host, "192.0.2.10")
        XCTAssertEqual(client.dials.first?.port, 8883)
        XCTAssertEqual(client.dials.first?.username, "bblp")
        XCTAssertEqual(client.dials.first?.password, "a1b2c3d4")
        let id = client.dials.first?.clientID ?? ""
        XCTAssertTrue(id.hasPrefix("pg-phone-700123-"), "its own ID, so it never knocks the Mac or the feed off: \(id)")
        XCTAssertFalse(id.contains("a1b2c3d4"))

        client.accept()
        XCTAssertEqual(client.subscriptions, ["device/20P9AJ5B0700123/report"])
        XCTAssertEqual(client.publishes.map(\.topic), ["device/20P9AJ5B0700123/request"])
        XCTAssertEqual(client.publishes.map(\.payload), [pushall], "read-only: pushall is the only publish")

        client.report(Report.running())
        guard case let .printer(row) = await task.value else { return XCTFail("expected a printer") }
        XCTAssertEqual(row.state, "RUNNING")
        XCTAssertEqual(row.percent, 52)
        XCTAssertEqual(row.remainingS, 84 * 60)
        XCTAssertEqual(row.name, "X2D")
        XCTAssertEqual(client.disconnects, 1)
        XCTAssertNil(client.onMessage, "a late report can't reach a finished fetch")
    }

    func testOneLookWaitsForAReportWithAState() async {
        let (client, task) = await fetching()
        client.accept()
        client.send(Data("not json".utf8))
        client.report(["mc_percent": 60])
        XCTAssertEqual(client.disconnects, 0, "a delta without a state isn't the full report")
        client.report(Report.state("RUNNING"))
        guard case let .printer(row) = await task.value else { return XCTFail("expected a printer") }
        XCTAssertEqual(row.percent, 60, "deltas before the full report merge in")
    }

    func testRejectedCodeEndsTheLookWithTheReason() async {
        let (client, task) = await fetching()
        client.drop("MQTT CONNACK 5")
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("MQTT CONNACK 5"))
        XCTAssertEqual(client.disconnects, 1)
    }

    func testSilentPrinterTimesOut() async {
        let (client, task) = await fetching(timeout: .milliseconds(50))
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("connect timed out"))
        XCTAssertEqual(client.disconnects, 1)
    }

    func testIncompletePrinterIsNotDialed() async {
        let client = FakeMQTT()
        let outcome = await PrinterFetch.fetch(.x2d(code: ""), client: client)
        XCTAssertEqual(outcome, .failed(nil))
        XCTAssertTrue(client.dials.isEmpty)
    }

    // MARK: Shared status

    func testStoreKeepsThePrinterAndItsLastStatus() {
        let store = PhoneStore(defaults: scratchDefaults())
        XCTAssertNil(store.printer)
        XCTAssertNil(store.status)

        store.save(PrinterSettings(ip: " 192.0.2.10 ", serial: "20P9AJ5B0700123", accessCode: "a1b2c3d4", name: "X2D"))
        XCTAssertEqual(store.printer, .x2d(), "saved trimmed")
        let status = PhoneStatus(printer: Rows.printing(), at: fetched)
        store.save(status)
        XCTAssertEqual(store.status, status)

        store.save(.x2d(ip: "192.0.2.11"))
        XCTAssertEqual(store.status, status, "a new IP for the same printer keeps what it said")
        store.save(PrinterSettings(ip: "192.0.2.12", serial: "01P00A000000001", accessCode: "c0de", name: "P1S"))
        XCTAssertNil(store.status, "another printer forgets the old one's status")
    }

    func testStoreIsAbsentOutsideTheIPhoneApp() {
        XCTAssertNil(PhoneStore.shared, "only a bundle whose Info.plist names PGAppGroup has one")
    }

    // MARK: What the widget says

    private func lines(_ row: Printer, at now: Date? = nil) -> PhoneLines {
        GlanceContent.phone(PhoneStatus(printer: row, at: fetched), hasPrinter: true, now: now ?? fetched, calendar: gmt, locale: gb)
    }

    func testPrintingCountsDownToTheFinishTime() {
        XCTAssertEqual(lines(Rows.printing()), PhoneLines(
            title: "Benchy",
            state: "Printing",
            hero: "15:26",
            detail: "1h 24m left",
            percent: 52,
            extra: ["Layer 18 / 29", "PLA Matte  80%"],
            footer: "Updated 14:02",
            short: "52% · 15:26",
            systemImage: "printer.fill"
        ))
        XCTAssertEqual(lines(Rows.printing(), at: fetched + 5).detail, "1h 24m left", "seconds after the look, still the printer's minutes")
        let later = lines(Rows.printing(), at: fetched + 30 * 60)
        XCTAssertEqual(later.hero, "15:26", "the finish time holds between looks")
        XCTAssertEqual(later.detail, "54m left")
        XCTAssertEqual(later.percent, 52, "the percent is what the printer said, not a guess")
        XCTAssertEqual(lines(Rows.printing(), at: fetched + 84 * 60 - 30).detail, "1m left")
        XCTAssertEqual(lines(Rows.printing(), at: fetched + 84 * 60).detail, "Should be done")
        XCTAssertEqual(lines(Rows.printing(), at: fetched + 24 * 3600).footer, "Updated 14:02 yesterday")
    }

    func testStartingNamesTheStage() {
        let l = lines(Rows.starting())
        XCTAssertEqual(l.state, "Heating")
        XCTAssertEqual(l.short, "Heating · 15:26")
        XCTAssertEqual(l.percent, 0)
    }

    func testPausedHoldsTimeLeftAndSaysWhy() {
        let l = lines(Rows.paused())
        XCTAssertEqual(l.state, "Paused")
        XCTAssertEqual(l.hero, "1h 24m left", "a paused finish time slides, so it shows time left")
        XCTAssertEqual(l.detail, "Filament ran out in AMS A, slot 1.")
        XCTAssertEqual(l.short, "Paused · 52%")
        XCTAssertEqual(l.systemImage, "pause.fill")
        XCTAssertTrue(l.alert)
        XCTAssertEqual(lines(Rows.paused(), at: fetched + 3600).hero, "1h 24m left")
    }

    func testFailedFinishedAndIdle() {
        let failed = lines(Rows.failed())
        XCTAssertEqual(failed.state, "Failed")
        XCTAssertEqual(failed.detail, GlanceContent.errorReason(Rows.failed()))
        XCTAssertNil(failed.percent)
        XCTAssertTrue(failed.alert)
        XCTAssertEqual(failed.systemImage, "xmark")

        let finished = lines(Rows.finished())
        XCTAssertEqual([finished.title, finished.state, finished.detail], ["Benchy", "Finished", "X2D"])
        XCTAssertNil(finished.hero)
        XCTAssertEqual(finished.short, "Finished")
        XCTAssertFalse(finished.alert)

        let idle = lines(Rows.idle())
        XCTAssertEqual([idle.title, idle.state, idle.short], ["X2D", "Idle", "Idle"])
        XCTAssertNil(idle.detail)
        XCTAssertEqual(idle.extra, [])
    }

    func testBeforeTheFirstLook() {
        let none = GlanceContent.phone(nil, hasPrinter: false, now: fetched)
        XCTAssertEqual([none.title, none.detail], ["Add your printer", "Open PrintGlance to set it up."])
        let unreached = GlanceContent.phone(nil, hasPrinter: true, now: fetched)
        XCTAssertEqual(unreached.title, "Can't reach printer")
        XCTAssertEqual(unreached.detail, "PrintGlance updates when this iPhone is on the printer's Wi-Fi.")
        XCTAssertNil(unreached.footer)
    }

    func testRedrawsEachMinuteUntilJustAfterTheFinish() {
        let printing = PhoneStatus(printer: Rows.printing(), at: fetched)
        let dates = GlanceContent.phoneEntryDates(printing, now: fetched)
        XCTAssertEqual(dates.count, 86, "now, then each minute to one past the 84-minute finish")
        XCTAssertEqual(dates.last, fetched + 85 * 60)
        XCTAssertEqual(GlanceContent.phoneEntryDates(printing, now: fetched + 2 * 3600), [fetched + 2 * 3600])

        var long = Rows.printing()
        long.remainingS = 10 * 3600
        XCTAssertEqual(GlanceContent.phoneEntryDates(PhoneStatus(printer: long, at: fetched), now: fetched).count, 121)
        XCTAssertEqual(GlanceContent.phoneEntryDates(PhoneStatus(printer: Rows.paused(), at: fetched), now: fetched), [fetched])
        XCTAssertEqual(GlanceContent.phoneEntryDates(nil, now: fetched), [fetched])
    }

    func testAsksAgainSoonerWhileAPrintRuns() {
        func next(_ row: Printer?) -> TimeInterval {
            GlanceContent.phoneNextFetch(row.map { PhoneStatus(printer: $0, at: fetched) }, now: fetched).timeIntervalSince(fetched)
        }
        XCTAssertEqual(next(Rows.printing()), 15 * 60)
        XCTAssertEqual(next(Rows.paused()), 15 * 60)
        XCTAssertEqual(next(Rows.idle()), 3600)
        XCTAssertEqual(next(nil), 3600)
        var nearlyDone = Rows.printing()
        nearlyDone.remainingS = 5 * 60
        XCTAssertEqual(next(nearlyDone), 6 * 60, "just after the finish time, to catch Finished")
    }

    func testFailureSaysWhatToCheckOnTheIPhone() {
        XCTAssertEqual(
            GlanceCopy.phoneFetchFailed(reason: "connect timed out"),
            "Can't reach the printer. Check that this iPhone is on the printer's Wi-Fi, and check the IP address. PrintGlance also needs Local Network access in Settings."
        )
        XCTAssertEqual(GlanceCopy.phoneFetchFailed(reason: "MQTT CONNACK 5"), GlanceCopy.feedDownDetail(reason: "MQTT CONNACK 5"))
        XCTAssertEqual(GlanceCopy.phoneFetchFailed(reason: "ECONNREFUSED"), GlanceCopy.feedDownDetail(reason: "ECONNREFUSED"))
    }

    // MARK: Finding printers

    func testSearchCoversTheSubnetButNotTheIPhone() {
        let home = PrinterSearch.neighbors(ip: "192.168.1.37", netmask: "255.255.255.0")
        XCTAssertEqual(home.count, 253)
        XCTAssertEqual(home.first, "192.168.1.1")
        XCTAssertEqual(home.last, "192.168.1.254")
        XCTAssertFalse(home.contains("192.168.1.37"))

        let big = PrinterSearch.neighbors(ip: "10.0.5.9", netmask: "255.255.0.0")
        XCTAssertEqual(big.count, 253, "a /16 searches only the /24 around the iPhone")
        XCTAssertEqual([big.first, big.last], ["10.0.5.1", "10.0.5.254"])
        XCTAssertEqual(PrinterSearch.neighbors(ip: "192.168.1.1", netmask: "255.255.255.252"), ["192.168.1.2"])
        XCTAssertEqual(PrinterSearch.neighbors(ip: "192.168.1.1", netmask: "255.255.255.255"), [])
        XCTAssertEqual(PrinterSearch.neighbors(ip: "not an address", netmask: "255.255.255.0"), [])
        XCTAssertEqual(PrinterSearch.neighbors(ip: "192.168.1.300", netmask: "255.255.255.0"), [])
    }

    func testOnlyASerialCountsAsAPrinter() {
        XCTAssertEqual(PrinterSearch.serial(fromCommonName: "20P9AJ5B0700123"), "20P9AJ5B0700123")
        XCTAssertEqual(PrinterSearch.serial(fromCommonName: "01P00A123456789"), "01P00A123456789")
        for other in ["localhost", "mqtt.home.lan", "Home Assistant", "ABC", "20p9aj5b0700123", "", nil] as [String?] {
            XCTAssertNil(PrinterSearch.serial(fromCommonName: other), "\(other ?? "nil")")
        }
    }

    func testPickingAnotherPrinterDropsTheOldCode() {
        let x2d = PrinterSettings.x2d()
        let other = PrinterSettings(ip: "192.0.2.51", serial: "20P9BJ5C2900999", accessCode: "", name: "")
        XCTAssertEqual(x2d.picking(other, saved: x2d), other, "the X2D's code would be rejected by the other printer")
        XCTAssertEqual(PrinterSettings.empty.picking(other, saved: nil), other)

        let movedX2D = PrinterSettings(ip: "192.0.2.80", serial: x2d.serial, accessCode: "", name: "")
        XCTAssertEqual(PrinterSettings.empty.picking(movedX2D, saved: x2d), .x2d(ip: "192.0.2.80"), "back to the saved printer: its code and name return")
        var typed = other
        typed.accessCode = "typed123"
        typed.name = "NCC-1701"
        XCTAssertEqual(typed.picking(other, saved: x2d), typed, "what was typed for this printer stays")
    }

    func testConnectSaysHowItWent() {
        XCTAssertEqual(GlanceCopy.phoneConnected(.printer(Rows.idle()), name: "NCC-1701"), PhoneAlert(
            title: "Connected to NCC-1701",
            message: "Its status shows at the top of this screen. To see it on your Home Screen, add the PrintGlance widget."
        ))
        XCTAssertEqual(GlanceCopy.phoneConnected(.failed("MQTT CONNACK 5"), name: "NCC-1701"), PhoneAlert(
            title: "Can't connect to NCC-1701",
            message: "The access code was rejected. Check the access code on the printer's LAN or Network page."
        ))
    }

    func testProbeReadsTheSerialFromTheCertificateAndSendsNothing() async throws {
        let broker = try FakeBroker(commonName: "20P9AJ5B0700123")
        let name = await PrinterSearch.commonName(host: "127.0.0.1", port: broker.port, timeout: 5)
        XCTAssertEqual(name, "20P9AJ5B0700123")
        XCTAssertTrue(broker.packets.isEmpty, "no MQTT login, no access code, no publish")
    }

    func testProbeGivesUpOnAClosedPort() async {
        let started = Date()
        let name = await PrinterSearch.commonName(host: "127.0.0.1", port: 1, timeout: 0.3)
        XCTAssertNil(name)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: The card

    func testCardReadsInOrder() throws {
        let small = try Screen(PhoneCard(lines: lines(Rows.printing())).frame(width: 140, height: 140))
        assertReadsWell(small)
        XCTAssertEqual(small.texts, ["Benchy", "Printing", "15:26", "1h 24m left", "52%", "Updated 14:02"])

        let medium = try Screen(PhoneCard(lines: lines(Rows.paused()), showsExtra: true).frame(width: 320, height: 140))
        assertReadsWell(medium)
        XCTAssertEqual(medium.texts, [
            "Benchy", "Paused", "1h 24m left", "Filament ran out in AMS A, slot 1.", "52%",
            "Layer 18 / 29", "PLA Matte  80%", "Updated 14:02",
        ])
    }
}
