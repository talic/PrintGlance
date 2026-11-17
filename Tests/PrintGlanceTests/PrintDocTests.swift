import AppKit
import XCTest
@testable import PrintGlance

final class PrintDocTests: XCTestCase {
    func testRunningFixtureDecodesAndStrip() throws {
        let doc = try load("print-running")
        XCTAssertEqual(doc.v, 1)
        let row = try XCTUnwrap(doc.displayRow())
        XCTAssertEqual(row.state, "RUNNING")
        XCTAssertEqual(row.percent, 16)
        XCTAssertEqual(row.remainingS, 16980)
        XCTAssertEqual(row.job, "Print in Parts")
        XCTAssertEqual(row.layer, 32)
        XCTAssertEqual(row.layerTotal, 230)
        XCTAssertEqual(row.eta, "18:30")
        XCTAssertEqual(row.filament, "PLA")
        XCTAssertEqual(row.filamentRemain, 42)

        let strip = GlanceContent.strip(row: row)
        XCTAssertEqual(strip.systemImage, "printer.fill")
        XCTAssertEqual(strip.title, "\u{2007}16%  18:30")
        XCTAssertTrue(strip.accessibilityLabel.contains("16 percent"))
        XCTAssertTrue(strip.accessibilityLabel.contains("18:30"))
        XCTAssertEqual(GlanceContent.hero(row), "18:30")
        XCTAssertEqual(GlanceContent.remainingLine(row), "4h 43m left")
        XCTAssertEqual(GlanceContent.layerLine(row), "Layer 32 / 230")
        XCTAssertEqual(GlanceContent.filamentLine(row), "PLA  42%")
    }

    func testIdleNullsDecode() throws {
        let doc = try load("print-idle")
        let row = try XCTUnwrap(doc.displayRow())
        XCTAssertEqual(row.state, "IDLE")
        XCTAssertNil(row.percent)
        XCTAssertNil(row.remainingS)
        XCTAssertNil(row.job)
        XCTAssertNil(row.eta)
        XCTAssertNil(row.layer)

        let strip = GlanceContent.strip(row: row)
        XCTAssertEqual(strip.systemImage, "printer")
        XCTAssertEqual(strip.title, "")
        XCTAssertNil(GlanceContent.hero(row))
    }

    func testEmptyPrintersIsPlainIconNotSubscript() throws {
        let doc = PrintDoc(v: 1, updatedAt: nil, focusId: nil, printers: [])
        XCTAssertNil(doc.displayRow())
        let strip = GlanceContent.strip(.doc(doc))
        XCTAssertEqual(strip.systemImage, "printer")
        XCTAssertEqual(strip.title, "")
    }

    func testUpdatedAtIgnoredForEquality() throws {
        let a = try load("print-idle")
        var b = a
        b.updatedAt = "2099-01-01T00:00:00Z"
        XCTAssertEqual(a, b)
        XCTAssertEqual(GlanceContent(result: .doc(a)), GlanceContent(result: .doc(b)))
        b.printers[0].percent = 1
        XCTAssertNotEqual(a, b)
    }

    func testPauseAndFinishAndFailedStrip() {
        var pause = Printer(id: "x2d", name: "X2D", state: "PAUSE", percent: 9)
        pause.eta = "16:25"
        pause.remainingS = 3600
        XCTAssertEqual(GlanceContent.strip(row: pause).title, "\u{2007}\u{2007}9%")
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "pause.fill")
        XCTAssertEqual(GlanceContent.strip(row: pause).accessibilityLabel, "X2D, paused, 9 percent")

        pause.state = "FINISH"
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "checkmark")
        XCTAssertEqual(GlanceContent.strip(row: pause).title, "")

        pause.state = "FAILED"
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "xmark")
        XCTAssertEqual(GlanceContent.strip(row: pause).accessibilityLabel, "X2D, failed, 9 percent")

        pause.printError = GlanceContent.cancelCode
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "stop.circle")
        XCTAssertEqual(GlanceContent.strip(row: pause).title, "")
        XCTAssertEqual(GlanceContent.strip(row: pause).accessibilityLabel, "X2D, canceled, 9 percent")
    }

    /// Before any report, one printer switched off mustn't show the moon over another that refuses its code.
    func testFeedDownReasonPutsARejectedCodeFirst() {
        XCTAssertEqual(GlanceCopy.feedDownReason(focused: "connect timed out", all: ["connect timed out", "MQTT CONNACK 5"]), "MQTT CONNACK 5")
        XCTAssertEqual(GlanceCopy.feedDownReason(focused: "ECONNREFUSED", all: ["connect timed out", "ECONNREFUSED"]), "ECONNREFUSED")
        XCTAssertEqual(GlanceCopy.feedDownReason(focused: nil, all: ["connect timed out"]), "connect timed out")
        XCTAssertNil(GlanceCopy.feedDownReason(focused: nil, all: []))
        XCTAssertEqual(GlanceContent.strip(.feedDown, feedDownReason: "MQTT CONNACK 5").systemImage, GlanceContent.offlineImage)
    }

    func testCanceledIsAFailureWithTheCancelCode() {
        var row = Printer(id: "x2d", name: "X2D", state: "FAILED", percent: 37, job: "Benchy", jobId: "t1")
        XCTAssertFalse(GlanceContent.isCanceled(row))
        XCTAssertEqual(GlanceContent.stateWord(row), "Failed")
        XCTAssertEqual(GlanceContent.listDetail(row), "Failed")

        row.printError = "0300-400C"
        XCTAssertTrue(GlanceContent.isCanceled(row))
        XCTAssertEqual(GlanceContent.stateWord(row), "Canceled")
        XCTAssertEqual(GlanceContent.listDetail(row), "Canceled")
        XCTAssertEqual(row.state, "FAILED", "the row keeps the printer's own state")
        XCTAssertEqual(GlanceContent.humanState(row.state), "Failed", "printers.json says what the printer said")

        XCTAssertEqual(GlanceContent.subtitle(row), "Canceled")
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "X2D · Canceled")
        XCTAssertEqual(GlanceContent.codeLines(row), [], "nothing to look up for a cancel")
        XCTAssertFalse(GlanceContent.showsErrors(row), "no codes block, not even No error reported.")
        XCTAssertEqual(GlanceContent.stoppedLine(row), "Stopped at 37%")

        row.hmsCode = "0300-9600-0001-0001"
        XCTAssertTrue(GlanceContent.isCanceled(row), "an HMS code beside the cancel doesn't make it a failure")
        XCTAssertEqual(GlanceContent.codeLines(row).map(\.code), ["0300-9600-0001-0001"], "the other code still shows")
        XCTAssertTrue(GlanceContent.showsErrors(row))
        row.hmsCode = nil
        row.state = "PAUSE"
        XCTAssertFalse(GlanceContent.isCanceled(row), "only a stopped print is canceled")
        XCTAssertEqual(GlanceContent.stateWord(row), "Paused")
        row.state = "OFFLINE"
        row.lastState = "FAILED"
        XCTAssertFalse(GlanceContent.isCanceled(row))
        XCTAssertEqual(GlanceContent.stateWord(row), "Offline")
    }

    func testFinishedTitleCollapsesAfterTwoHours() {
        let ended = Date(timeIntervalSince1970: 1_700_000_000)
        let row = Printer(id: "x2d", name: "X2D", state: "FINISH", percent: 100)
        let fresh = GlanceContent.strip(row: row, occupancyEndedAt: ended, now: ended + 119 * 60)
        XCTAssertEqual(fresh.title, "1h 59m ago")
        XCTAssertEqual(fresh.accessibilityLabel, "X2D, finished 1h 59m ago")
        let stale = GlanceContent.strip(row: row, occupancyEndedAt: ended, now: ended + 190 * 60)
        XCTAssertEqual(stale.title, "")
        XCTAssertEqual(stale.systemImage, "checkmark")
        XCTAssertEqual(stale.accessibilityLabel, "X2D, finished 3h 10m ago")
    }

    func testOfflineStripIsNotIdle() {
        var offline = Printer(id: "x2d", name: "X2D", state: "OFFLINE", percent: 62)
        offline.lastState = "RUNNING"
        let idle = Printer(id: "x2d", name: "X2D", state: "IDLE")
        XCTAssertEqual(GlanceContent.strip(row: offline).systemImage, "wifi.slash")
        XCTAssertEqual(GlanceContent.strip(row: offline).title, "")
        XCTAssertEqual(GlanceContent.strip(row: idle).systemImage, "printer")
    }

    func testOfflineSaysLostOnlyForAPrintAndSleepsOtherwise() {
        var row = Printer(id: "x2d", name: "X2D", state: "OFFLINE", percent: 62)
        func kind(_ last: String?, rejected: Bool? = nil) -> GlanceContent.OfflineKind? {
            row.lastState = last
            row.codeRejected = rejected
            return GlanceContent.offlineKind(row)
        }
        XCTAssertEqual(kind("RUNNING"), .lost)
        XCTAssertEqual(kind("PREPARE"), .lost)
        XCTAssertEqual(kind("PAUSE"), .lost)
        XCTAssertEqual(kind("PAUSE", rejected: true), .lost, "a print in progress comes first")
        XCTAssertEqual(kind(nil, rejected: true), .codeRejected)
        XCTAssertEqual(kind("IDLE", rejected: true), .codeRejected)
        for last in ["IDLE", "FINISH", "FAILED", nil] {
            XCTAssertEqual(kind(last), .switchedOff, last ?? "never reached")
        }

        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "powersleep")
        XCTAssertEqual(GlanceContent.strip(row: row).title, "")
        XCTAssertEqual(GlanceContent.strip(row: row).accessibilityLabel, "X2D, offline")
        XCTAssertEqual(GlanceContent.subtitle(row), "Offline")
        XCTAssertEqual(GlanceContent.listDetail(row), "Offline")
        row.codeRejected = true
        XCTAssertEqual(GlanceContent.strip(row: row).systemImage, "wifi.slash", "a rejected code needs you")
        row.state = "IDLE"
        XCTAssertNil(GlanceContent.offlineKind(row))
    }

    func testOfflineDetailIsCalmWhenThePrinterIsProbablySwitchedOff() {
        let calm = "It may be switched off. If it's on, check Wi-Fi and the IP address."
        var row = Printer(id: "x2d", name: "X2D", state: "OFFLINE")
        row.lastState = "IDLE"
        XCTAssertEqual(GlanceCopy.offlineDetail(row, reason: "connect timed out"), calm)
        XCTAssertEqual(GlanceCopy.offlineDetail(row, reason: nil), calm)
        XCTAssertEqual(
            GlanceCopy.offlineDetail(row, reason: "ECONNREFUSED"),
            "It may be switched off or still starting up. If it's on, check the IP address on the printer's LAN or Network page."
        )
        XCTAssertEqual(
            GlanceCopy.offlineDetail(row, reason: "MQTT CONNACK 5"),
            GlanceCopy.feedDownDetail(reason: "MQTT CONNACK 5"),
            "the link knows before the row does"
        )

        row.lastState = "RUNNING"
        for reason in ["connect timed out", "ECONNREFUSED", "MQTT CONNACK 5"] {
            XCTAssertEqual(GlanceCopy.offlineDetail(row, reason: reason), GlanceCopy.feedDownDetail(reason: reason), "lost mid-print: \(reason)")
        }

        XCTAssertEqual(GlanceCopy.offlineDetail(nil, reason: "connect timed out"), calm, "no printer answered at launch")
        XCTAssertEqual(GlanceCopy.offlineDetail(nil, reason: "MQTT CONNACK 5"), GlanceCopy.feedDownDetail(reason: "MQTT CONNACK 5"))
    }

    func testStartingShowsShortStage() {
        XCTAssertEqual(GlanceContent.shortStage("Loading filament"), "Loading")
        XCTAssertEqual(GlanceContent.shortStage("Unloading filament"), "Unloading")
        XCTAssertEqual(GlanceContent.shortStage("Cleaning nozzle"), "Cleaning")
        XCTAssertEqual(GlanceContent.shortStage("Heating"), "Heating")
        XCTAssertEqual(GlanceContent.shortStage(nil), "Starting")
        var row = Printer(id: "x2d", name: "X2D", state: "PREPARE", percent: 0)
        row.stage = "Loading filament"
        XCTAssertEqual(GlanceContent.strip(row: row).title, "Loading")
        XCTAssertEqual(GlanceContent.subtitle(row), "Loading filament")
    }

    func testEveryStripImageIsARealSymbol() {
        var images: Set<String> = [
            GlanceContent.strip(.feedDown).systemImage,
            GlanceContent.strip(.connecting).systemImage,
            GlanceContent.strip(.needsSetup).systemImage,
        ]
        images.insert(GlanceContent.strip(.feedDown, feedDownReason: "MQTT CONNACK 5").systemImage)
        var canceled = Printer(id: "x", name: "X", state: "FAILED")
        canceled.printError = GlanceContent.cancelCode
        images.insert(GlanceContent.strip(row: canceled).systemImage)
        var lost = Printer(id: "x", name: "X", state: "OFFLINE")
        lost.lastState = "RUNNING"
        images.insert(GlanceContent.strip(row: lost).systemImage)
        for state in ["PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE"] {
            images.insert(GlanceContent.strip(row: Printer(id: "x", name: "X", state: state)).systemImage)
        }
        for name in images {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testPercentPaddingStableWidth() {
        XCTAssertEqual(GlanceContent.paddedPercent(9), "\u{2007}\u{2007}9%")
        XCTAssertEqual(GlanceContent.paddedPercent(16), "\u{2007}16%")
        XCTAssertEqual(GlanceContent.paddedPercent(100), "100%")
    }

    func testCardRulesPerState() {
        var row = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: 52, job: "Benchy", jobId: "t1")
        row.remainingS = 84 * 60
        row.eta = "16:25"
        let ended = Date(timeIntervalSince1970: 1_700_000_000)
        let now = ended + 40 * 60
        func hero(_ state: String, endedAt: Date? = nil) -> String? {
            var r = row
            r.state = state
            return GlanceContent.hero(r, occupancyEndedAt: endedAt, now: now)
        }
        func with(_ state: String) -> Printer {
            var r = row
            r.state = state
            return r
        }

        XCTAssertEqual(GlanceContent.headline(row), "Benchy")
        XCTAssertEqual(GlanceContent.headline(with("FINISH")), "Benchy")
        XCTAssertEqual(GlanceContent.headline(with("IDLE")), "X2D", "idle names the printer, not the last job")

        XCTAssertEqual(hero("RUNNING"), "16:25")
        XCTAssertEqual(GlanceContent.remainingLine(row), "1h 24m left")
        XCTAssertEqual(hero("PREPARE"), "16:25")
        XCTAssertEqual(hero("PAUSE"), "1h 24m left", "the iPhone's paused card leads with time left")
        XCTAssertNil(GlanceContent.cardHero(with("PAUSE")), "the Mac's paused card leads with the reason")
        XCTAssertEqual(GlanceContent.cardHero(row), "16:25")
        XCTAssertEqual(GlanceContent.remainingLine(with("PAUSE")), "1h 24m left", "under the paused bar instead")
        var pausedUnknown = with("PAUSE")
        pausedUnknown.remainingS = nil
        XCTAssertNil(GlanceContent.hero(pausedUnknown))
        XCTAssertNil(GlanceContent.remainingLine(pausedUnknown))
        XCTAssertEqual(hero("FINISH", endedAt: ended), "40m ago")
        XCTAssertNil(hero("FINISH"), "unknown finish time shows no hero, not Finished twice")
        XCTAssertNil(hero("FAILED"))
        XCTAssertNil(hero("IDLE"))

        XCTAssertEqual(
            ["RUNNING", "PREPARE", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE"].filter { GlanceContent.showsAMS(with($0)) },
            ["PAUSE", "FINISH", "FAILED", "IDLE"]
        )
        XCTAssertEqual(
            ["RUNNING", "PREPARE", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE"].filter { GlanceContent.showsProgress(with($0)) },
            ["RUNNING", "PAUSE"],
            "Starting has no bar or layer yet"
        )
    }

    func testSubtitleNamesThePrinterWhenThereAreSeveral() {
        var row = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: 52, job: "Benchy", jobId: "t1")
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "X2D · Printing")
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: false), "Printing", "one printer needs no name")
        row.state = "PREPARE"
        row.stage = "Heating"
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "X2D · Heating")
        row.state = "PAUSE"
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "X2D · Paused")
        row.state = "FINISH"
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "X2D · Finished")
        row.state = "IDLE"
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "Idle", "the headline already names it")
        row.state = "RUNNING"
        row.job = nil
        XCTAssertEqual(GlanceContent.subtitle(row, namingPrinter: true), "Printing", "no job: the headline is the printer")
    }

    func testFinishedHeroTurnsIntoTheClockTimeAfterTwoHours() {
        let gb = Locale(identifier: "en_GB")
        // Saturday 2026-08-22 10:00 GMT; the print finished 14:02 the day before.
        let now = Date(timeIntervalSince1970: 1_787_392_800)
        let ended = Date(timeIntervalSince1970: 1_787_320_920)
        var row = Printer(id: "x2d", name: "X2D", state: "FINISH", job: "Benchy", jobId: "t1")
        func hero(_ ended: Date) -> String? {
            GlanceContent.cardHero(row, occupancyEndedAt: ended, now: now, calendar: gmt, locale: gb)
        }
        XCTAssertEqual(hero(now - 40 * 60), "40m ago")
        XCTAssertEqual(hero(now - GlanceContent.finishTitleFor + 60), "1h 59m ago")
        XCTAssertEqual(hero(now - GlanceContent.finishTitleFor), "08:00", "the menu bar's cutoff")
        XCTAssertEqual(hero(ended), "14:02 yesterday")
        XCTAssertNil(GlanceContent.cardHero(row, now: now), "no time when PrintGlance didn't see it end")

        XCTAssertEqual(GlanceContent.tookLine(row, startedAt: ended - 283 * 60, endedAt: ended), "Took 4h 43m")
        XCTAssertNil(GlanceContent.tookLine(row, startedAt: ended - 283 * 60, endedAt: nil), "the end wasn't seen")
        XCTAssertNil(GlanceContent.tookLine(row, startedAt: nil, endedAt: ended))
        XCTAssertNil(GlanceContent.tookLine(row, startedAt: ended - 30, endedAt: ended), "not \"Took 0m\"")
        row.state = "FAILED"
        XCTAssertNil(GlanceContent.tookLine(row, startedAt: ended - 283 * 60, endedAt: ended))
    }

    func testFailedSaysWhereItStopped() {
        var row = Printer(id: "x2d", name: "X2D", state: "FAILED", percent: 52, job: "Benchy", jobId: "t1")
        row.layer = 18
        row.layerTotal = 29
        XCTAssertEqual(GlanceContent.stoppedLine(row), "Stopped at 52% · Layer 18 / 29")
        row.layer = 0
        XCTAssertEqual(GlanceContent.stoppedLine(row), "Stopped at 52%", "no layer 0")
        row.layer = nil
        XCTAssertEqual(GlanceContent.stoppedLine(row), "Stopped at 52%")
        row.percent = 0
        XCTAssertNil(GlanceContent.stoppedLine(row), "it never got going")
        row.percent = nil
        XCTAssertNil(GlanceContent.stoppedLine(row))
        row.percent = 52
        row.state = "PAUSE"
        XCTAssertNil(GlanceContent.stoppedLine(row), "a paused card has the bar")
    }

    func testFilamentDotsKeepAnEdgeAgainstThePanel() {
        func edge(_ hex: String, dark: Bool) -> Double { GlanceContent.dotOutline(hex: hex, dark: dark) }
        XCTAssertGreaterThan(edge("000000FF", dark: true), edge("000000FF", dark: false), "black in dark mode needs the edge")
        XCTAssertGreaterThan(edge("FFFFFFFF", dark: false), edge("FFFFFFFF", dark: true), "white in light mode needs it")
        XCTAssertEqual(edge("333333FF", dark: true), edge("000000FF", dark: true), "dark gray too")
        XCTAssertEqual(edge("F5C6A0FF", dark: false), edge("FFFFFFFF", dark: false), "pale colors in light mode")
        XCTAssertLessThan(edge("F5C6A0FF", dark: false), edge("000000FF", dark: true), "lighter, so pale colors don't look heavy")
        XCTAssertEqual(edge("2850E0FF", dark: false), 0.15, "a color that stands out keeps a faint edge")
        XCTAssertEqual(edge("FF6600FF", dark: true), 0.15)
        XCTAssertEqual(edge("FFFFFF10", dark: true), edge("000000FF", dark: true), "nearly clear takes the panel's color")
        XCTAssertEqual(edge("00000010", dark: false), edge("FFFFFFFF", dark: false))
        XCTAssertEqual(edge("not hex", dark: true), 0)
    }

    func testOfflineCardKeepsLastKnownProgress() {
        let gb = Locale(identifier: "en_GB")
        // Saturday 2026-08-22 14:02 GMT
        let seen = Date(timeIntervalSince1970: 1_787_407_320)
        var row = Printer(id: "x2d", name: "X2D", state: "OFFLINE", percent: 52, job: "Benchy", jobId: "t1")
        row.remainingS = 143 * 60
        row.layer = 18
        row.layerTotal = 29
        row.lastSeen = seen
        row.lastState = "RUNNING"
        func lines(at now: Date) -> [String] {
            GlanceContent.offlineLines(row, now: now, calendar: gmt, locale: gb)
        }

        XCTAssertEqual(lines(at: seen + 600), [
            "Last update 14:02",
            "Was printing · 52% · Layer 18 / 29",
            "Expected to finish 16:25",
        ])
        XCTAssertEqual(lines(at: seen + 3 * 3600).last, "Was due to finish 16:25")
        XCTAssertEqual(GlanceContent.headline(row), "Benchy")
        XCTAssertEqual(GlanceContent.subtitle(row), "Offline")
        XCTAssertEqual(
            GlanceContent.strip(row: row, now: seen + 600, calendar: gmt, locale: gb).accessibilityLabel,
            "X2D, offline, last update 14:02"
        )

        row.lastState = "PAUSE"
        XCTAssertEqual(lines(at: seen + 600), ["Last update 14:02", "Was paused at 52%"])

        row.lastState = "IDLE"
        XCTAssertEqual(lines(at: seen + 600), ["Last update 14:02"])
        XCTAssertEqual(GlanceContent.headline(row), "X2D")

        row.lastSeen = nil
        row.lastState = nil
        XCTAssertEqual(lines(at: seen), [])
        XCTAssertEqual(GlanceContent.strip(row: row).accessibilityLabel, "X2D, offline")
    }

    func testFeedDownStrip() {
        XCTAssertEqual(GlanceContent.strip(.feedDown).systemImage, "powersleep", "printers switched off overnight")
        XCTAssertEqual(GlanceContent.strip(.feedDown, feedDownReason: "connect timed out").systemImage, "powersleep")
        XCTAssertEqual(GlanceContent.strip(.feedDown, feedDownReason: "ECONNREFUSED").systemImage, "powersleep")
        XCTAssertEqual(GlanceContent.strip(.feedDown, feedDownReason: "MQTT CONNACK 5").systemImage, "wifi.slash")
        XCTAssertEqual(GlanceContent.strip(.feedDown).accessibilityLabel, "Can't reach printer")
        XCTAssertEqual(GlanceContent.strip(.feedDown).title, "")
    }

    func testOneWordPerState() {
        XCTAssertEqual(GlanceContent.humanState("FINISH"), "Finished")
        XCTAssertEqual(GlanceContent.humanState("PREPARE"), "Starting")
        XCTAssertEqual(GlanceContent.downloadTitle(tag: "v1.2.0"), "Download PrintGlance 1.2.0")
        XCTAssertEqual(GlanceContent.downloadTitle(tag: "1.2.0"), "Download PrintGlance 1.2.0")
    }

    func testConnectingStripIsNotFeedDown() {
        XCTAssertEqual(GlanceContent.strip(.connecting).systemImage, "printer")
        XCTAssertEqual(GlanceContent.strip(.connecting).title, "…", "not the idle printer")
        XCTAssertEqual(GlanceContent.strip(.connecting).accessibilityLabel, "Connecting to printer")
        XCTAssertNotEqual(
            GlanceContent.strip(.connecting).systemImage,
            GlanceContent.strip(.feedDown).systemImage
        )
    }

    func testFeedDownDetailTokens() {
        XCTAssertEqual(
            GlanceCopy.feedDownDetail(reason: "ECONNREFUSED"),
            "The printer refused the connection. It may still be starting up, or another device may have its IP address now. Check the IP address on the printer's LAN or Network page."
        )
        XCTAssertEqual(
            GlanceCopy.feedDownDetail(reason: "MQTT CONNACK 5"),
            "The access code was rejected. Check the access code on the printer's LAN or Network page."
        )
        XCTAssertEqual(
            GlanceCopy.feedDownDetail(reason: "connect timed out"),
            "Can't reach the printer. Check Wi-Fi and the IP address."
        )
        XCTAssertEqual(
            GlanceCopy.feedDownDetail(reason: nil),
            "Can't reach the printer. Check Wi-Fi and the IP address."
        )
    }

    func testNeedsSetupStrip() {
        XCTAssertEqual(GlanceContent.strip(.needsSetup).systemImage, "printer")
        XCTAssertEqual(GlanceContent.strip(.needsSetup).title, "Set Up", "not the idle printer")
        XCTAssertEqual(GlanceContent.strip(.needsSetup).accessibilityLabel, "Add your Bambu printer")
    }

    func testMigrateSingularSettings() throws {
        let name = "PrintGlance.migrate.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.removePersistentDomain(forName: name)
        d.set("192.0.2.10", forKey: "printerIP")
        d.set("01S123", forKey: "printerSerial")
        d.set("code", forKey: "printerAccessCode")
        d.set("X2D", forKey: "printerName")

        let first = SavedPrinters.load(from: d)
        XCTAssertEqual(first.printers.count, 1)
        XCTAssertEqual(first.printers[0].ip, "192.0.2.10")
        XCTAssertEqual(first.printers[0].serial, "01S123")
        XCTAssertEqual(first.printers[0].accessCode, "code")
        XCTAssertEqual(first.printers[0].name, "X2D")
        XCTAssertNil(first.focusId)
        XCTAssertTrue(first.isComplete)

        d.set("203.0.113.9", forKey: "printerIP")
        let second = SavedPrinters.load(from: d)
        XCTAssertEqual(second.printers[0].ip, "192.0.2.10")
    }

    func testDisplayRowRanksWhoNeedsYou() {
        func p(_ id: String, _ state: String, left: Int? = nil) -> Printer {
            var row = Printer(id: id, name: id.uppercased(), state: state)
            row.remainingS = left
            return row
        }
        let idle = p("idle", "IDLE")
        let idle2 = p("idle2", "IDLE")
        let offline = p("off", "OFFLINE")
        var lost = p("lost", "OFFLINE")
        lost.lastState = "RUNNING"
        var rejected = p("rejected", "OFFLINE")
        rejected.codeRejected = true
        let done = p("done", "FINISH")
        let failed = p("fail", "FAILED")
        var canceled = p("cancel", "FAILED")
        canceled.printError = GlanceContent.cancelCode
        let paused = p("pause", "PAUSE", left: 600)
        let paused2 = p("pause2", "PAUSE", left: 60)
        let long = p("long", "RUNNING", left: 7200)
        let soon = p("soon", "RUNNING", left: 600)
        let starting = p("start", "PREPARE", left: 300)
        let unknown = p("unknown", "RUNNING")
        let same = p("same", "RUNNING", left: 600)

        let cases: [(String, [Printer], String?, String?)] = [
            ("paused beats printing", [long, paused], nil, "pause"),
            ("paused beats the focused printer", [long, paused], "long", "pause"),
            ("two paused: saved order", [paused, paused2], nil, "pause"),
            ("two paused: focus breaks the tie", [paused, paused2], "pause2", "pause2"),
            ("printing: finishing soonest", [long, soon], nil, "soon"),
            ("printing: starting counts", [long, starting], nil, "start"),
            ("printing: focused beats finishing soonest", [long, soon], "long", "long"),
            ("printing: unknown time sorts last", [unknown, long], nil, "long"),
            ("printing: equal time goes to saved order", [soon, same], nil, "soon"),
            ("failed does not beat printing", [failed, long], nil, "long"),
            ("failed beats finished", [done, failed], nil, "fail"),
            ("finished beats idle and offline", [idle, offline, done], nil, "done"),
            ("lost mid-print beats failed", [failed, lost], nil, "lost"),
            ("printing beats lost mid-print", [lost, long], nil, "long"),
            ("paused beats lost mid-print", [lost, paused], nil, "pause"),
            ("canceled is below failed", [canceled, failed], nil, "fail"),
            ("canceled ranks with finished: saved order", [canceled, done], nil, "cancel"),
            ("canceled ranks with finished: focus", [canceled, done], "done", "done"),
            ("canceled beats idle", [idle, canceled], nil, "cancel"),
            ("focused idle beats the first", [idle, idle2], "idle2", "idle2"),
            ("nothing going on: the first", [idle, offline], nil, "idle"),
            ("idle beats switched off", [offline, idle], nil, "idle"),
            ("focus doesn't lift switched off over idle", [offline, idle], "off", "idle"),
            ("a rejected code ranks with idle: saved order", [rejected, idle], nil, "rejected"),
            ("a rejected code ranks with idle: focus", [idle, rejected], "rejected", "rejected"),
            ("switched off alone still shows", [offline], nil, "off"),
            ("focus on a missing printer", [idle], "gone", "idle"),
            ("no printers", [], nil, nil),
        ]
        for (name, printers, focus, want) in cases {
            XCTAssertEqual(PrintDoc(v: 1, updatedAt: nil, focusId: focus, printers: printers).displayRow()?.id, want, name)
        }
    }

    func testEmptyListIsNeedsSetup() throws {
        XCTAssertFalse(SavedPrinters.empty.isComplete)
        XCTAssertFalse(SavedPrinters(printers: [PrinterSettings.empty], focusId: nil).isComplete)

        let name = "PrintGlance.empty.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.removePersistentDomain(forName: name)
        d.set("192.0.2.10", forKey: "printerIP")
        d.set("01S123", forKey: "printerSerial")
        d.set("code", forKey: "printerAccessCode")
        _ = SavedPrinters.load(from: d)
        SavedPrinters.empty.save(to: d)
        XCTAssertFalse(SavedPrinters.load(from: d).isComplete)
    }

    func testReplacingOntoExistingSerialDropsTheOtherRow() {
        let a = PrinterSettings(ip: "192.0.2.10", serial: "aaa", accessCode: "x", name: "Alpha")
        let b = PrinterSettings(ip: "192.0.2.11", serial: "bbb", accessCode: "y", name: "Beta")
        let c = PrinterSettings(ip: "192.0.2.12", serial: "ccc", accessCode: "z", name: "Gamma")
        var edited = c
        edited.serial = "aaa"
        let next = SavedPrinters(printers: [a, b, c], focusId: "aaa").replacing(edited, serial: "ccc")
        XCTAssertEqual(next.printers, [b, edited])
        XCTAssertEqual(next.focusId, "aaa")
    }

    func testTwoPrintersBothInDoc() {
        let a = PrinterSettings(ip: "192.0.2.10", serial: "aaa", accessCode: "x", name: "Alpha")
        let b = PrinterSettings(ip: "192.0.2.11", serial: "bbb", accessCode: "y", name: "Beta")
        let snapA = BambuSnapshot(printerID: "aaa", name: "Alpha")
        snapA.ingest(["print": ["gcode_state": "RUNNING", "mc_percent": 20]])
        let snapB = BambuSnapshot(printerID: "bbb", name: "Beta")
        snapB.ingest(["print": ["gcode_state": "IDLE"]])
        let doc = BambuSnapshot.fleetDoc(
            printers: [a, b],
            snapshots: ["aaa": snapA, "bbb": snapB],
            focusId: nil
        )
        XCTAssertEqual(doc.printers.count, 2)
        XCTAssertEqual(doc.printers.map(\.id), ["aaa", "bbb"])
        XCTAssertEqual(doc.printers[0].state, "RUNNING")
        XCTAssertEqual(doc.printers[1].state, "IDLE")
        XCTAssertEqual(doc.displayRow()?.id, "aaa")
    }

    func testJobLabelStripsProcessSuffix() {
        XCTAssertEqual(
            BambuPrint.jobLabel(["subtask_name": "Print in Parts 0.16mm layer, 2 walls, 10% infill"]),
            "Print in Parts"
        )
        XCTAssertNil(BambuPrint.humanGcodeStem("cache/012345678.gcode"))
        XCTAssertEqual(BambuPrint.humanGcodeStem("models/stomp-t-rex.gcode"), "stomp-t-rex")
    }

    func testJobLabelKeepsSizesAndDropsEveryExtension() {
        XCTAssertEqual(BambuPrint.humanGcodeStem("/sdcard/Benchy.gcode.3mf"), "Benchy")
        XCTAssertEqual(BambuPrint.humanGcodeStem("Benchy.3MF"), "Benchy")
        XCTAssertEqual(BambuPrint.humanGcodeStem("Benchy.stl"), "Benchy.stl")
        XCTAssertNil(BambuPrint.humanGcodeStem(".gcode.3mf"))
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Spacer 20mm x4"), "Spacer 20mm x4")
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Cable clip 1.5mm"), "Cable clip 1.5mm")
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Benchy 0.2MM"), "Benchy")
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Benchy .08mm"), "Benchy")
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Spacer 20mm 0.2mm layer, 2 walls"), "Spacer 20mm")
        XCTAssertEqual(BambuPrint.stripProcessSuffix("Benchy_0.2mm"), "Benchy_0.2mm", "no space, not a suffix")
    }

    func testMergeClearsLayerOnNewJob() {
        var dst: [String: Any] = [
            "subtask_name": "old",
            "layer_num": 90,
            "gcode_file": "old.gcode",
            "gcode_state": "RUNNING",
        ]
        BambuPrint.merge(&dst, incoming: ["subtask_name": "new", "gcode_state": "RUNNING"])
        XCTAssertNil(dst["layer_num"])
        XCTAssertNil(dst["gcode_file"])
    }

    func testEtaQualifiesFinishDay() {
        let cal = gmt
        let gb = Locale(identifier: "en_GB")
        // Saturday 2026-08-22 10:00 GMT
        let morning = Date(timeIntervalSince1970: 1_787_392_800)
        func eta(_ s: Int, _ now: Date, _ locale: Locale = gb) -> String? {
            BambuPrint.etaHM(state: "RUNNING", remainingS: s, now: now, calendar: cal, locale: locale)
        }
        XCTAssertEqual(eta(30_600, morning), "18:30")
        XCTAssertEqual(eta(26 * 3600, morning), "12:00 tomorrow")
        XCTAssertEqual(eta(203_400, morning), "18:30 Mon")
        // Saturday 2026-08-22 22:00 GMT, 3h overnight
        let evening = Date(timeIntervalSince1970: 1_787_436_000)
        XCTAssertEqual(eta(3 * 3600, evening), "01:00 tomorrow")

        let us = Locale(identifier: "en_US")
        XCTAssertEqual(spaced(eta(30_600, morning, us)), "6:30 PM")
        XCTAssertEqual(spaced(eta(3 * 3600, evening, us)), "1:00 AM tomorrow")
        XCTAssertNil(BambuPrint.etaHM(state: "IDLE", remainingS: 600, now: morning, calendar: cal, locale: gb))
    }

    func testDayTimeEitherSide() {
        let gb = Locale(identifier: "en_GB")
        let us = Locale(identifier: "en_US")
        // Saturday 2026-08-22 10:00 GMT
        let now = Date(timeIntervalSince1970: 1_787_392_800)
        func at(_ hours: Double, _ locale: Locale = gb) -> String {
            GlanceContent.dayTime(now + hours * 3600, now: now, calendar: gmt, locale: locale)
        }
        XCTAssertEqual(at(4), "14:00")
        XCTAssertEqual(at(-4), "06:00")
        XCTAssertEqual(at(-12), "22:00 yesterday")
        XCTAssertEqual(at(-48), "10:00 Thu")
        XCTAssertEqual(at(6 * 24), "10:00 Fri")
        XCTAssertEqual(at(7 * 24, us), "Aug 29")
        XCTAssertEqual(at(-7 * 24, gb), "15 Aug")
        XCTAssertEqual(spaced(at(-12, us)), "10:00 PM yesterday")
    }

    func testFormatRemainUsesDaysPastADay() {
        XCTAssertEqual(GlanceContent.formatRemain(0), "0m")
        XCTAssertEqual(GlanceContent.formatRemain(5 * 60), "5m")
        XCTAssertEqual(GlanceContent.formatRemain(84 * 60), "1h 24m")
        XCTAssertEqual(GlanceContent.formatRemain(23 * 3600 + 59 * 60), "23h 59m")
        XCTAssertEqual(GlanceContent.formatRemain(26 * 3600 + 5 * 60), "1d 2h")
        XCTAssertEqual(GlanceContent.agoTitle(from: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 51 * 3600)), "2d 3h ago")
    }

    private var gmt: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// ICU puts U+202F before AM/PM; compare with a plain space.
    private func spaced(_ s: String?) -> String? {
        s?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testActiveNozzleLeftRight() {
        XCTAssertEqual(BambuPrint.activeNozzle(dualNozzle(state: 2)), "Right")
        XCTAssertEqual(BambuPrint.activeNozzle(dualNozzle(state: 18)), "Left")
        XCTAssertEqual(BambuPrint.activeNozzle(dualNozzle(state: 33042)), "Left")
        XCTAssertNil(BambuPrint.activeNozzle(["gcode_state": "RUNNING"]))
        XCTAssertNil(BambuPrint.activeNozzle([
            "device": ["extruder": ["state": 1, "info": [["id": 0]]]],
        ]))

        let right = BambuPrint.row(
            id: "h2d",
            name: "H2D",
            printObj: dualNozzle(state: 2, extra: ["gcode_state": "RUNNING"]),
            online: true
        )
        XCTAssertEqual(right.nozzle, "Right")
        XCTAssertEqual(GlanceContent.filamentLine(right), "Right")

        var withFil = right
        withFil.filament = "PLA"
        withFil.filamentRemain = 42
        XCTAssertEqual(GlanceContent.filamentLine(withFil), "PLA  42% · Right")
        XCTAssertTrue(GlanceContent.strip(row: withFil).accessibilityLabel.contains("right nozzle"))
    }

    func testRowOfflineKeepsPercent() {
        let row = BambuPrint.row(
            id: "x2d",
            name: "X2D",
            printObj: ["gcode_state": "RUNNING", "mc_percent": 62],
            online: false
        )
        XCTAssertEqual(row.state, "OFFLINE")
        XCTAssertEqual(row.percent, 62)
    }

    private func dualNozzle(state: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var obj: [String: Any] = [
            "device": [
                "extruder": [
                    "state": state,
                    "info": [["id": 0], ["id": 1]],
                ],
            ],
        ]
        for (k, v) in extra {
            obj[k] = v
        }
        return obj
    }

    private func load(_ name: String) throws -> PrintDoc {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONCoding.decoder.decode(PrintDoc.self, from: Data(contentsOf: url))
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension Printer {
    init(
        id: String,
        name: String,
        state: String,
        percent: Int? = nil,
        job: String? = nil,
        jobId: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            state: state,
            percent: percent,
            remainingS: nil,
            job: job,
            layer: nil,
            layerTotal: nil,
            eta: nil,
            filament: nil,
            filamentRemain: nil,
            jobId: jobId
        )
    }
}
