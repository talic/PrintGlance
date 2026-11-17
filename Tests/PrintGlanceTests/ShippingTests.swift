import Foundation
import XCTest
@testable import PrintGlance

/// What ships with the app and what the README promises, checked against the code that keeps the promise.
/// When one of these fails, change the README and the code together.
final class ShippingTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func file(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(name), encoding: .utf8)
    }

    private func readme(contains phrase: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try self.file("README.md").contains(phrase), "README no longer says: \(phrase)", file: file, line: line)
    }

    // MARK: - Info.plist

    func testInfoPlistKeepsTheAppAMenuBarApp() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "local.PrintGlance",
                       "saved printers, history, and the Keychain service hang off this ID; changing it loses them")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true, "no Dock icon")
        XCTAssertEqual(plist["LSMultipleInstancesProhibited"] as? Bool, true, "two copies would both hold MQTT sessions")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "PrintGlance")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertTrue(try file("Package.swift").contains(".macOS(.v14)"), "Package.swift and Info.plist agree on macOS 14")
        let why = try XCTUnwrap(plist["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertTrue(why.contains("Bambu printers"), "macOS shows this when discovery first runs")
        let version = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), "release.yml matches tags v\(version)")
        XCTAssertNotNil(Int(try XCTUnwrap(plist["CFBundleVersion"] as? String)))
    }

    func testAccessCodeKeychainServiceMatchesTheBundle() {
        XCTAssertEqual(AccessCodeStore.service, "local.PrintGlance.accessCode", "1.1.7 saved codes under this service")
    }

    // MARK: - README promises

    func testPrinterLimit() throws {
        try readme(contains: "PrintGlance watches up to four printers.")
        XCTAssertEqual(SavedPrinters.maxCount, 4)
    }

    func testHistoryLength() throws {
        try readme(contains: "PrintGlance keeps the last 50 jobs on this Mac")
        XCTAssertEqual(JobLog.cap, 50)
    }

    func testClearHistoryKeepsAPrintInProgress() throws {
        try readme(contains: "To clear it, click **Clear History…** below the list, then click **Clear**. A print in progress stays.")
        var log = JobLog(rows: [
            JobLogRow(serial: "x2d", name: "X2D", jobId: "t1", startAt: Date(), outcome: nil),
            JobLogRow(serial: "x2d", name: "X2D", jobId: "t0", startAt: Date(), outcome: JobLog.outcomeOK),
        ])
        log.clearEnded()
        XCTAssertEqual(log.rows.map(\.jobId), ["t1"])
    }

    func testLowFilamentThreshold() throws {
        try readme(contains: "drops below 20%")
        XCTAssertEqual(FilamentAlert.thresholdPercent, 20)
        try readme(contains: "It ignores readings below 5%")
        XCTAssertEqual(RunoutTracker.floor, 5)
    }

    func testFinishTimeLearnsFromTheLastFivePrints() throws {
        try readme(contains: "the middle of that printer's last five prints")
        XCTAssertEqual(Overrun.keep, 5)
    }

    func testQuietHours() throws {
        try readme(contains: "choose **9 PM–6 AM**, **10 PM–7 AM**, **11 PM–8 AM**, or **Midnight–9 AM**")
        try readme(contains: "**Print Finished** waits until the hours end")
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(
            PrintNotifyPrefs.quietHoursChoices.map { GlanceContent.quietHoursChoice($0, locale: us) },
            ["Off", "9 PM–6 AM", "10 PM–7 AM", "11 PM–8 AM", "Midnight–9 AM"]
        )
        XCTAssertEqual(QuietHours.starts.map { QuietHours(startHour: $0).endHour }, [6, 7, 8, 9])
        try readme(contains: "On a 24-hour clock they read **22:00–07:00**.")
        XCTAssertEqual(GlanceContent.quietHoursChoice(.default, locale: Locale(identifier: "en_GB")), "22:00–07:00")
        try readme(contains: "such as **Quiet Hours (10 PM–7 AM)** or **Quiet Hours (Off)**")
        XCTAssertEqual(GlanceContent.quietHoursTitle(.default, locale: us), "Quiet Hours (10 PM–7 AM)")
        XCTAssertEqual(GlanceContent.quietHoursTitle(nil, locale: us), "Quiet Hours (Off)")
    }

    func testNotificationDefaults() throws {
        try readme(contains: "**Quiet Hours** starts turned off. The others start turned on.")
        let d = scratchDefaults()
        let prefs = PrintNotifyPrefs.load(d)
        XCTAssertEqual([prefs.pause, prefs.fail, prefs.finish, prefs.comingOff, prefs.offline, prefs.lowFilament], Array(repeating: true, count: 6))
        XCTAssertFalse(prefs.quietHours)
        XCTAssertNil(prefs.quietWindow)
        XCTAssertEqual(prefs.quietHoursStart, 22, "Quiet Hours turned on before the choice keeps 10 PM–7 AM")
    }

    func testFinishingSoonLeadTimes() throws {
        try readme(contains: "choose **5 Minutes Before**, **10 Minutes Before**, **15 Minutes Before**, or **30 Minutes Before**. To stop it, choose **Off**. It starts at 10 minutes.")
        XCTAssertEqual(
            PrintNotifyPrefs.finishingSoonChoices.map(GlanceContent.finishingSoonChoice(lead:)),
            ["Off", "5 Minutes Before", "10 Minutes Before", "15 Minutes Before", "30 Minutes Before"]
        )
        XCTAssertEqual(PrintNotifyPrefs.load(scratchDefaults()).finishingSoonLead, 10)
        try readme(contains: "such as **Print Finishing Soon (10 Min Before)**")
        XCTAssertEqual(GlanceContent.finishingSoonTitle(lead: 10), "Print Finishing Soon (10 Min Before)")
    }

    @MainActor
    func testLookUpOnNotices() throws {
        try readme(contains: "A paused or failed notice with an error code also has **Look Up**.")
        XCTAssertEqual(GlanceModel.lookUpCategory().actions.map(\.title), ["Look Up"])
    }

    func testLostConnectionSettle() throws {
        try readme(contains: "or for 2 minutes after this Mac's network changes")
        XCTAssertEqual(PrintNotify.networkSettle, 120)
    }

    func testFinishedTitleCollapses() throws {
        try readme(contains: "After 2 hours, only the checkmark")
        XCTAssertEqual(GlanceContent.finishTitleFor, 2 * 3600)
    }

    func testDailyUpdateCheck() throws {
        try readme(contains: "Once a day PrintGlance checks GitHub.")
        XCTAssertEqual(AppUpdate.day, 24 * 60 * 60)
    }

    func testMenuBarStageWords() throws {
        try readme(contains: "**Heating**, **Leveling**, **Loading**, **Unloading**, **Calibrating**, **Cleaning**, **Homing**, or **Starting**")
        let words = Set((0...255).map { GlanceContent.shortStage(BambuPrint.stageLabel(state: "PREPARE", printObj: ["stg_cur": $0])) })
        XCTAssertEqual(words, ["Heating", "Leveling", "Loading", "Unloading", "Calibrating", "Cleaning", "Homing", "Starting"])
    }

    func testPausedExampleReadsAsTheREADMEShowsIt() throws {
        try readme(contains: "**Filament ran out in AMS A, slot 2.**")
        try readme(contains: "**Error 0700-2100-0002-0001**")
        XCTAssertEqual(GlanceContent.errorReason(code: "0700-2100-0002-0001"), "Filament ran out in AMS A, slot 2.")
    }

    func testPausedNoticeReadsAsTheREADMEShowsIt() throws {
        try readme(contains: "A paused print reads **X2D paused**, then **Benchy · 52%**, then a short reason")
        var notify = PrintNotify(serial: "x2d", prefs: .default, stamps: [:])
        let row = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: 52, job: "Benchy", jobId: "t1")
        _ = notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [row]))))
        var paused = row
        paused.state = "PAUSE"
        paused.hmsCode = "0700-2100-0002-0001"
        let alert = notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [paused])))).alert
        XCTAssertEqual(alert?.title, "X2D paused")
        XCTAssertEqual(alert?.subtitle, "Benchy · 52%")
        XCTAssertEqual(alert?.body, "Filament ran out in AMS A, slot 2.")
    }

    func testMenuBarRankingReadsAsTheREADMEListsIt() throws {
        try readme(contains: "3. A printer that lost its connection during a print\n4. A failed printer\n5. A finished or canceled printer")
        try readme(contains: "7. A printer that is probably switched off: it wasn't printing when PrintGlance last heard from it, or it hasn't answered since PrintGlance started")
        func p(_ id: String, _ state: String) -> Printer { Printer(id: id, name: id, state: state) }
        var lost = p("lost", "OFFLINE")
        lost.lastState = "PAUSE"
        var canceled = p("canceled", "FAILED")
        canceled.printError = GlanceContent.cancelCode
        var wasIdle = p("wasIdle", "OFFLINE")
        wasIdle.lastState = "IDLE"
        let never = p("never", "OFFLINE")
        let shuffled = [never, wasIdle, p("idle", "IDLE"), canceled, p("failed", "FAILED"), lost, p("printing", "RUNNING"), p("paused", "PAUSE")]
        XCTAssertEqual(
            PrintDoc(v: 1, focusId: nil, printers: shuffled).ranked().map(\.id),
            ["paused", "printing", "lost", "failed", "canceled", "idle", "never", "wasIdle"]
        )
    }

    func testCanceledPrintIsCalm() throws {
        try readme(contains: "| Canceled | A stop icon | **Canceled**, in gray, and the AMS trays. The printer reports a canceled print as failed, but PrintGlance tells them apart and sends no **Print Failed** notice |")
        var notify = PrintNotify(serial: "x2d", prefs: .default, stamps: [:])
        var row = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: 52, job: "Benchy", jobId: "t1")
        _ = notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [row]))))
        row.state = "FAILED"
        row.printError = "0300-400C"
        XCTAssertNil(notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [row])))).alert)
        XCTAssertEqual(GlanceContent.stateWord(row), "Canceled")
        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "stop.circle")
    }

    func testOfflineMenuBarAndWords() throws {
        try readme(contains: "A Wi-Fi icon with a slash if the printer was printing or paused, or rejected its access code. Otherwise a moon: the printer is probably switched off")
        try readme(contains: "With the moon, the card says **It may be switched off.**")
        var row = Printer(id: "x2d", name: "X2D", state: "OFFLINE")
        row.lastState = "IDLE"
        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "powersleep", "the moon")
        XCTAssertTrue(GlanceCopy.offlineDetail(row, reason: "connect timed out").hasPrefix("It may be switched off."))
        row.lastState = "PAUSE"
        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "wifi.slash")
        row.lastState = "IDLE"
        row.codeRejected = true
        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "wifi.slash")
    }

    func testMenuBarBeforeAReport() throws {
        try readme(contains: "Until you add a printer, **Set Up** shows next to it.")
        XCTAssertEqual(GlanceContent.strip(.needsSetup).title, "Set Up")
        try readme(contains: "While PrintGlance connects, **…** shows next to the printer icon.")
        XCTAssertEqual(GlanceContent.strip(.connecting).title, "…")
    }

    func testHistoryOutcomeWords() throws {
        try readme(contains: "**Finished**, **Failed**, **Canceled**, or **Printing**. **Failed** is red, with the reason below it when the printer gave one, such as **The nozzle may be clogged.**")
        var row = JobLogRow(serial: "x2d", name: "X2D", jobId: "t1", startAt: Date(), outcome: nil)
        var words = [GlanceContent.historyOutcome(row)]
        row.outcome = JobLog.outcomeOK
        words.append(GlanceContent.historyOutcome(row))
        row.outcome = JobLog.outcomeFail
        row.failCode = "0300-4006"
        words.append(GlanceContent.historyOutcome(row))
        XCTAssertEqual(GlanceContent.historyNotes(row), ["The nozzle may be clogged."])
        row.failCode = GlanceContent.cancelCode
        words.append(GlanceContent.historyOutcome(row))
        XCTAssertEqual(words, ["Printing", "Finished", "Failed", "Canceled"])
    }

    func testSlotNames() throws {
        try readme(contains: "(**A1**…**D4**, **HT-A**, **External**)")
        XCTAssertEqual(BambuPrint.unitLabel(3), "D")
        XCTAssertEqual(BambuPrint.unitLabel(128), "HT-A")
    }

    func testLostConnectionNoticeWording() throws {
        try readme(contains: "**Lost connection to X2D** with **Benchy was at 52%. PrintGlance keeps trying.**")
        var notify = PrintNotify(serial: "x2d", prefs: .default, stamps: [:])
        let row = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: 52, job: "Benchy", jobId: "t1")
        _ = notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [row]))))
        var offline = row
        offline.state = "OFFLINE"
        let alert = notify.observe(GlanceContent(result: .doc(PrintDoc(v: 1, focusId: nil, printers: [offline])))).alert
        XCTAssertEqual(alert?.title, "Lost connection to X2D")
        XCTAssertEqual(alert?.body, "Benchy was at 52%. PrintGlance keeps trying.")
    }

    func testReadOnlyAndLocalPromise() throws {
        try readme(contains: "It never pauses, stops, or starts a print.")
        try readme(contains: "The only thing it fetches from the internet is a daily check on GitHub for a newer version.")
        // The only URLs the app requests itself; Bambu's pages open in the browser only when clicked.
        let sources = try FileManager.default.contentsOfDirectory(
            at: Self.root.appendingPathComponent("Sources/PrintGlance"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var requested: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("session.data(") || text.contains("dataTask(") { requested.append(url.lastPathComponent) }
        }
        XCTAssertEqual(requested, ["AppUpdate.swift"])
    }
}
