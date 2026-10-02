import XCTest
@testable import PrintGlance

/// End-to-end workflows through `GlanceModel`, with the test playing the printer over a fake connection.
/// Nothing here touches the network, Notification Center, or this Mac's preferences.
@MainActor
final class GlanceModelTests: XCTestCase {
    private let x2d = PrinterSettings.x2d()
    private let p1s = PrinterSettings.p1s()
    private let pushall = #"{"pushing":{"command":"pushall","sequence_id":"0"}}"#

    // MARK: - First run and connecting

    func testFirstLaunchAsksForSetupAndDialsNothing() {
        let h = ModelHarness(self)
        XCTAssertEqual(h.model.content.result, .needsSetup)
        XCTAssertEqual(h.model.strip.accessibilityLabel, "Add your Bambu printer")
        XCTAssertTrue(h.model.linkStatus.isEmpty)
        XCTAssertTrue(h.printers.clients.isEmpty)
    }

    func testAddingAPrinterDialsItWithTheAccessCode() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        let dial = try XCTUnwrap(link.dials.first)
        XCTAssertEqual(dial.host, "192.0.2.10")
        XCTAssertEqual(dial.port, 8883)
        XCTAssertEqual(dial.username, "bblp")
        XCTAssertEqual(dial.password, "a1b2c3d4")
        XCTAssertTrue(dial.clientID.hasPrefix("pg-app-700123-"), "the Python feed uses pg-feed-; a shared ID makes the printer drop one")
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .connecting)
        XCTAssertEqual(h.model.content.result, .connecting)
        XCTAssertEqual(h.model.strip.accessibilityLabel, "Connecting to printer")
    }

    func testHandshakeSubscribesAndAsksForEverything() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .connected)
        XCTAssertEqual(link.subscriptions, ["device/20P9AJ5B0700123/report"])
        XCTAssertEqual(link.publishes.map(\.topic), ["device/20P9AJ5B0700123/request"])
        XCTAssertEqual(link.publishes.map(\.payload), [pushall])
        XCTAssertEqual(h.model.content.result, .connecting, "connected but no report yet")
    }

    func testIncompletePrinterIsNotDialed() {
        let h = ModelHarness(self)
        var half = x2d
        half.accessCode = "  "
        h.model.saveSettings(SavedPrinters.empty.adding(half))
        XCTAssertTrue(h.printers.clients.isEmpty)
        XCTAssertEqual(h.model.content.result, .needsSetup)
    }

    func testSavedPrintersPersistInTheInjectedDefaults() {
        let h = ModelHarness(self)
        h.add(x2d, p1s)
        let reloaded = SavedPrinters.load(from: h.defaults)
        XCTAssertEqual(reloaded.printers.map(\.serial), [x2d.serial, p1s.serial])
        XCTAssertEqual(reloaded.printers.first?.accessCode, "a1b2c3d4")
    }

    // MARK: - Reports become the card and the menu bar

    func testReportBecomesTheCardAndMenuBar() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        let row = try XCTUnwrap(h.row(x2d.serial))
        XCTAssertEqual(row.state, "RUNNING")
        XCTAssertEqual(row.percent, 52)
        XCTAssertEqual(row.job, "Benchy")
        XCTAssertEqual(row.layer, 18)
        XCTAssertEqual(row.layerTotal, 29)
        XCTAssertEqual(row.remainingS, 84 * 60)
        XCTAssertNotNil(row.eta)
        XCTAssertEqual(h.model.strip.systemImage, "printer.fill")
        XCTAssertTrue(h.model.strip.title.contains("52%"), h.model.strip.title)
    }

    func testPartialReportsMergeIntoTheLastOne() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(["mc_percent": 53])
        let row = try XCTUnwrap(h.row(x2d.serial))
        XCTAssertEqual(row.percent, 53)
        XCTAssertEqual(row.job, "Benchy", "a delta keeps the job")
        XCTAssertEqual(row.layer, 18)
    }

    func testANewJobDropsTheOldLayerCount() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(["gcode_state": "RUNNING", "task_id": "t2", "subtask_name": "Next", "mc_percent": 1])
        let row = try XCTUnwrap(h.row(x2d.serial))
        XCTAssertEqual(row.job, "Next")
        XCTAssertNil(row.layer, "layer 18 belonged to the last job")
    }

    func testGarbageMessagesChangeNothing() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        for raw in ["", "not json", "[1,2,3]", #"{"print":"RUNNING"}"#, #"{"print":{}}"#, #"{"info":{"command":"get_version"}}"#] {
            link.send(Data(raw.utf8))
        }
        link.send(Data([0xFF, 0xFE, 0x00]))
        let row = try XCTUnwrap(h.row(x2d.serial))
        XCTAssertEqual(row.state, "RUNNING")
        XCTAssertEqual(row.percent, 52)
        XCTAssertEqual(row.job, "Benchy")
    }

    func testMenuBarShowsThePausedPrinterOverThePrintingOne() throws {
        let h = ModelHarness(self)
        let links = h.add(x2d, p1s)
        links.forEach { $0.accept() }
        links[0].report(Report.running())
        links[1].report(Report.running().merging(["gcode_state": "PAUSE"]))
        XCTAssertEqual(h.doc?.displayRow()?.id, p1s.serial)
        XCTAssertEqual(h.model.strip.systemImage, "pause.fill")
        XCTAssertEqual(h.doc?.printers.map(\.id), [x2d.serial, p1s.serial], "the list keeps saved order")
    }

    func testClickingAPrinterFocusesItAndRemembersTheChoice() throws {
        let h = ModelHarness(self)
        let links = h.add(x2d, p1s)
        links.forEach { $0.accept() }
        links[0].report(Report.running(minutesLeft: 30))
        links[1].report(Report.running(minutesLeft: 90))
        XCTAssertEqual(h.doc?.displayRow()?.id, x2d.serial, "finishing soonest")
        h.model.focusPrinter(p1s.serial)
        XCTAssertEqual(h.doc?.displayRow()?.id, p1s.serial)
        XCTAssertEqual(SavedPrinters.load(from: h.defaults).focusId, p1s.serial)
        XCTAssertEqual(links[0].disconnects, 0, "focus is not a settings change")
    }

    // MARK: - Losing the printer

    func testRejectedAccessCodeRetriesWithoutSearchingTheNetwork() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.drop("MQTT CONNACK 5")
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .failed(reason: "MQTT CONNACK 5"))
        XCTAssertEqual(h.model.disconnectReason(for: x2d.serial), "MQTT CONNACK 5")
        XCTAssertEqual(h.model.content.result, .feedDown)
        XCTAssertEqual(h.model.strip.systemImage, "wifi.slash")
        let retried = await eventually { link.dials.count == 2 }
        XCTAssertTrue(retried, "backoff redials after a second")
        XCTAssertEqual(h.network.scans, 0, "the printer answered, so its IP is right")
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .failed(reason: "MQTT CONNACK 5"), "stays failed through retries")
    }

    func testDroppedPrinterKeepsItsProgressThroughTheGrace() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.drop("closed")
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .failed(reason: "closed"))
        XCTAssertEqual(h.row(x2d.serial)?.state, "RUNNING", "30 s grace before Offline")
        XCTAssertEqual(h.row(x2d.serial)?.percent, 52)
    }

    func testReconnectingClearsTheFailure() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.drop("closed")
        link.accept()
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .connected)
        XCTAssertNil(h.model.disconnectReason(for: x2d.serial))
    }

    func testReconnectDuringTheSearchIsNotRedialed() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.drop("closed")
        link.accept()
        let searched = await eventually { h.network.scans == 1 }
        XCTAssertTrue(searched)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(link.dials.count, 1, "the search finished after the printer came back; a redial would drop it")
        XCTAssertEqual(h.model.linkStatus[x2d.serial], .connected)
    }

    func testPrinterThatMovedIsFoundAndItsNewAddressSaved() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        h.network.hits = [PrinterDiscovery.Hit(ip: "192.0.2.99", serial: x2d.serial.lowercased(), name: "X2D", model: "N6")]
        link.drop("ECONNREFUSED")
        let redialed = await eventually { link.dials.last?.host == "192.0.2.99" }
        XCTAssertTrue(redialed)
        XCTAssertEqual(h.network.scans, 1)
        XCTAssertEqual(h.model.settings.printers.first?.ip, "192.0.2.10", "not saved until it answers")
        link.accept()
        XCTAssertEqual(h.model.settings.printers.first?.ip, "192.0.2.99")
        XCTAssertEqual(SavedPrinters.load(from: h.defaults).printers.first?.ip, "192.0.2.99")
        XCTAssertEqual(h.printers.clients.count, 1, "adopting an IP is not a settings change")
        XCTAssertTrue(h.logText.contains("ip \(x2d.serial) 192.0.2.10 -> 192.0.2.99"))
    }

    func testANewAddressThatFailsIsNotSaved() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        h.network.hits = [PrinterDiscovery.Hit(ip: "192.0.2.99", serial: x2d.serial, name: "", model: "")]
        link.drop("connect timed out")
        let tried = await eventually { link.dials.last?.host == "192.0.2.99" }
        XCTAssertTrue(tried)
        link.drop("connect timed out")
        let back = await eventually { link.dials.last?.host == "192.0.2.10" }
        XCTAssertTrue(back, "a failed candidate reverts to the saved IP")
        XCTAssertEqual(SavedPrinters.load(from: h.defaults).printers.first?.ip, "192.0.2.10")
        XCTAssertEqual(h.network.scans, 1, "one search a minute at most")
    }

    func testEditingAPrinterPausesRediscovery() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        h.model.setRediscoverPausedSerial(" \(x2d.serial.lowercased()) ")
        h.network.hits = [PrinterDiscovery.Hit(ip: "192.0.2.99", serial: x2d.serial, name: "", model: "")]
        link.drop("closed")
        let retried = await eventually { link.dials.count == 2 }
        XCTAssertTrue(retried)
        XCTAssertEqual(h.network.scans, 1)
        XCTAssertEqual(link.dials.last?.host, "192.0.2.10", "the setup window owns this printer's IP while open")
    }

    func testSilentPrinterTimesOutAndIsSearchedFor() async throws {
        let h = ModelHarness(self, connectTimeout: .milliseconds(50))
        let link = try XCTUnwrap(h.add(x2d).first)
        let failed = await eventually { h.model.linkStatus[self.x2d.serial] == .failed(reason: "connect timed out") }
        XCTAssertTrue(failed)
        XCTAssertGreaterThanOrEqual(link.disconnects, 1, "the half-open socket is closed")
        let searched = await eventually { h.network.scans == 1 }
        XCTAssertTrue(searched)
    }

    // MARK: - Changing printers

    func testSavingSettingsReplacesEveryConnection() throws {
        let h = ModelHarness(self)
        let old = try XCTUnwrap(h.add(x2d).first)
        h.add(p1s)
        XCTAssertEqual(old.disconnects, 1)
        XCTAssertNil(old.onMessage, "a late message from the old socket goes nowhere")
        XCTAssertNil(old.onDisconnect)
        XCTAssertEqual(h.printers.clients.count, 3, "one for the first save, two for the second")
    }

    func testRemovingAPrinterStopsWatchingIt() throws {
        let h = ModelHarness(self)
        let links = h.add(x2d, p1s)
        links.forEach { $0.accept() }
        links.forEach { $0.report(Report.running()) }
        h.model.removePrinter(serial: p1s.serial)
        XCTAssertEqual(links[1].disconnects, 1)
        XCTAssertEqual(h.model.settings.printers.map(\.serial), [x2d.serial])
        XCTAssertNil(h.model.linkStatus[p1s.serial])
        h.model.removePrinter(serial: x2d.serial)
        XCTAssertEqual(h.model.content.result, .needsSetup)
    }

    func testRelaunchReconnectsToSavedPrinters() throws {
        let h = ModelHarness(self, saved: SavedPrinters(printers: [x2d, p1s], focusId: p1s.serial))
        XCTAssertEqual(h.model.settings.focusId, p1s.serial)
        h.model.saveSettings(h.model.settings)
        XCTAssertNotNil(h.printers.latest(x2d.serial))
        XCTAssertNotNil(h.printers.latest(p1s.serial))
    }

    // MARK: - Notifications

    func testFirstPrintAsksForNotificationPermissionOnce() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(Report.running(percent: 53))
        let asked = await eventually { h.notifications.permissionRequests == 1 }
        XCTAssertTrue(asked)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.notifications.permissionRequests, 1)
    }

    func testFinishedPrintNotifiesWithThePrinter() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(Report.state("FINISH"))
        let finish = try XCTUnwrap(h.notifications.posted.first { $0.title == "Print finished" })
        XCTAssertEqual(finish.id, "pg.finish.\(x2d.serial)")
        XCTAssertEqual(finish.body, "Benchy on X2D")
        XCTAssertEqual(finish.serial, x2d.serial, "clicking it opens the card on this printer")
        XCTAssertNil(finish.fireIn)
        XCTAssertNil(finish.calendar, "Quiet Hours is off")
    }

    func testPauseNotificationSaysWhyAndGivesTheCode() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(["gcode_state": "PAUSE", "hms": [["attr": 0x0700_2000, "code": 0x0002_0001]]])
        let pause = try XCTUnwrap(h.notifications.posted.first { $0.title == "Print paused" })
        XCTAssertEqual(pause.body, "Filament ran out in AMS A, slot 1. Benchy on X2D · Error 0700-2000-0002-0001")
    }

    func testFailedPrintNotifies() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(["gcode_state": "FAILED", "print_error": 0x0300_806E])
        let fail = try XCTUnwrap(h.notifications.posted.first { $0.title == "Print failed" })
        XCTAssertEqual(fail.body, "The nozzle overheated. Turn the printer off and have it checked. Benchy on X2D · Error 0300-806E")
    }

    func testTurnedOffNotificationsStayOffAndAreSaved() throws {
        let h = ModelHarness(self)
        h.model.notifyPrefs.finish = false
        h.model.notifyPrefs.comingOff = false
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        link.report(Report.state("FINISH"))
        XCTAssertFalse(h.notifications.titles().contains("Print finished"))
        XCTAssertFalse(h.notifications.titles().contains("Print finishing soon"))
        XCTAssertFalse(PrintNotifyPrefs.load(h.defaults).finish)
    }

    func testFinishingSoonIsScheduledAndCanceledByPause() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running(minutesLeft: 84))
        let soon = try XCTUnwrap(h.notifications.posted.first { $0.title == "Print finishing soon" })
        let id = "pg.comingoff.\(x2d.serial).t1"
        XCTAssertEqual(soon.id, id)
        XCTAssertEqual(soon.fireIn, 74 * 60, "10 minutes before the end")
        XCTAssertEqual(soon.body, "Benchy on X2D. About 10 minutes left.")
        let cancelledBefore = h.notifications.cancelled.count
        link.report(["gcode_state": "PAUSE"])
        XCTAssertEqual(h.notifications.cancelled.dropFirst(cancelledBefore).first, id)
        XCTAssertEqual(h.notifications.posted.filter { $0.id == id }.count, 1)
    }

    func testLeadTimeMovesTheFinishingSoonNotice() throws {
        let h = ModelHarness(self)
        h.model.notifyPrefs.comingOffLead = 30
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running(minutesLeft: 84))
        XCTAssertEqual(h.notifications.posted.first { $0.title == "Print finishing soon" }?.fireIn, 54 * 60)
        XCTAssertEqual(PrintNotifyPrefs.load(h.defaults).comingOffLead, 30)
    }

    func testLowFilamentNotifiesOncePerSpoolAndJob() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running().merging(Report.ams(remain: 15)))
        link.report(Report.running(percent: 53).merging(Report.ams(remain: 14)))
        let low = h.notifications.posted.filter { $0.title == "Low filament" }
        XCTAssertEqual(low.count, 1)
        XCTAssertEqual(low.first?.body, "X2D is using PLA Matte at 15%.")
        XCTAssertEqual(low.first?.id, "filament.\(x2d.serial)|0|t1")
    }

    func testLowFilamentOffSendsNothing() throws {
        let h = ModelHarness(self)
        h.model.notifyPrefs.lowFilament = false
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running().merging(Report.ams(remain: 15)))
        XCTAssertFalse(h.notifications.titles().contains("Low filament"))
    }

    func testFallingSpoolMarksTheBarAndNotifiesOnce() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        // Two points of spool per percent of progress: empty at 25%.
        for p in 10...17 {
            link.report(Report.running(percent: p, minutesLeft: 100 - p).merging(Report.ams(remain: 50 - p * 2)))
        }
        let runout = try XCTUnwrap(h.row(x2d.serial)?.runout)
        XCTAssertTrue((24...25).contains(runout.percent), "\(runout.percent)")
        XCTAssertEqual(runout.tray, "A1")
        XCTAssertEqual(runout.name, "PLA Matte")
        let notices = h.notifications.posted.filter { $0.title == "Filament may run out" }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.body.hasPrefix("X2D: PLA Matte in A1 runs out") == true, notices.first?.body ?? "")
        XCTAssertNotNil(h.defaults.data(forKey: RunoutTracker.defaultsKey), "survives a relaunch mid-print")
    }

    func testClickedNotificationPicksTheCardOnce() {
        let h = ModelHarness(self)
        h.model.notificationClicked(serial: p1s.serial)
        XCTAssertEqual(h.model.takePendingSelection(), p1s.serial)
        XCTAssertNil(h.model.takePendingSelection())
    }

    func testNotificationsOffIsRead() async {
        let h = ModelHarness(self)
        h.notifications.denied = true
        h.model.refreshNotificationStatus()
        let off = await eventually { h.model.notificationsOff }
        XCTAssertTrue(off)
    }

    // MARK: - History

    func testFinishedPrintIsLoggedAndSurvivesARelaunch() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running())
        XCTAssertEqual(h.model.historyRows.first?.outcome, nil, "open while printing")
        link.report(Report.state("FINISH"))
        let row = try XCTUnwrap(h.model.historyRows.first)
        XCTAssertEqual(row.job, "Benchy")
        XCTAssertEqual(row.outcome, JobLog.outcomeOK)
        XCTAssertNotNil(row.endedAt)
        XCTAssertNotNil(h.model.occupancyEndedAt, "the menu bar can say how long ago")
        XCTAssertEqual(h.model.strip.title, "0m ago")
        h.relaunch()
        XCTAssertEqual(h.model.historyRows.map(\.job), ["Benchy"])
        XCTAssertEqual(h.model.historyRows.map(\.outcome), [JobLog.outcomeOK])
        XCTAssertEqual(h.model.historyRows.first?.endedAt?.timeIntervalSince1970 ?? 0, row.endedAt!.timeIntervalSince1970, accuracy: 1)
    }

    func testClearingHistoryForgetsPastPrintsOnDisk() throws {
        let h = ModelHarness(self)
        let links = h.add(x2d, p1s)
        links.forEach { $0.accept() }
        links[0].report(Report.running())
        links[0].report(Report.state("FINISH"))
        links[1].report(Report.running(job: "Gears", task: "t9"))
        XCTAssertEqual(h.model.historyRows.count, 2)
        XCTAssertEqual(h.model.strip.systemImage, "printer.fill", "the running printer has the menu bar")

        h.model.clearHistory()
        XCTAssertEqual(h.model.historyRows.map(\.job), ["Gears"], "the print in progress stays")
        XCTAssertNil(h.model.occupancyEndedAt(for: try XCTUnwrap(h.row(x2d.serial))))
        h.relaunch()
        XCTAssertEqual(h.model.historyRows.map(\.job), ["Gears"])
    }

    func testExportWritesCSV() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(x2d).first)
        link.accept()
        link.report(Report.running(job: "Bracket, left"))
        link.report(Report.state("FAILED"))
        let url = h.dir.appendingPathComponent("out.csv")
        h.model.exportHistory(to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.first, "started,ended,duration_min,printer,job,filament,outcome")
        XCTAssertTrue(lines.last?.hasSuffix(#",X2D,"Bracket, left",,fail"#) == true, String(lines.last ?? ""))
    }
}
