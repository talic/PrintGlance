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
        let offline = Printer(id: "x2d", name: "X2D", state: "OFFLINE", percent: 62)
        let idle = Printer(id: "x2d", name: "X2D", state: "IDLE")
        XCTAssertEqual(GlanceContent.strip(row: offline).systemImage, "wifi.slash")
        XCTAssertEqual(GlanceContent.strip(row: offline).title, "")
        XCTAssertEqual(GlanceContent.strip(row: idle).systemImage, "printer")
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
        XCTAssertEqual(hero("PAUSE"), "1h 24m left")
        XCTAssertNil(GlanceContent.remainingLine(with("PAUSE")), "paused shows time left once, as the hero")
        var pausedUnknown = with("PAUSE")
        pausedUnknown.remainingS = nil
        XCTAssertNil(GlanceContent.hero(pausedUnknown))
        XCTAssertEqual(hero("FINISH", endedAt: ended), "40m ago")
        XCTAssertNil(hero("FINISH"), "unknown finish time shows no hero, not Finished twice")
        XCTAssertNil(hero("FAILED"))
        XCTAssertNil(hero("IDLE"))

        XCTAssertEqual(GlanceContent.caption(with("FINISH")), "X2D")
        XCTAssertEqual(GlanceContent.caption(with("FAILED")), "X2D")
        XCTAssertNil(GlanceContent.caption(with("IDLE")))
        XCTAssertNil(GlanceContent.caption(row))

        XCTAssertEqual(
            ["RUNNING", "PREPARE", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE"].filter { GlanceContent.showsAMS(with($0)) },
            ["PAUSE", "FINISH", "FAILED", "IDLE"]
        )
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
        XCTAssertEqual(GlanceContent.strip(.feedDown).systemImage, "wifi.slash")
        XCTAssertEqual(GlanceContent.strip(.feedDown).accessibilityLabel, "Can't reach printer")
    }

    func testOneWordPerState() {
        XCTAssertEqual(GlanceContent.humanState("FINISH"), "Finished")
        XCTAssertEqual(GlanceContent.humanState("PREPARE"), "Starting")
        XCTAssertEqual(GlanceContent.downloadTitle(tag: "v1.2.0"), "Download PrintGlance 1.2.0")
        XCTAssertEqual(GlanceContent.downloadTitle(tag: "1.2.0"), "Download PrintGlance 1.2.0")
    }

    func testConnectingStripIsNotFeedDown() {
        XCTAssertEqual(GlanceContent.strip(.connecting).systemImage, "printer")
        XCTAssertNotEqual(
            GlanceContent.strip(.connecting).systemImage,
            GlanceContent.strip(.feedDown).systemImage
        )
    }

    func testFeedDownDetailTokens() {
        XCTAssertEqual(
            GlanceCopy.feedDownDetail(reason: "ECONNREFUSED"),
            "The printer is on the Wi-Fi, but it isn't accepting a local connection. On the printer, open Settings, then LAN or Network, and turn on LAN mode."
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
        let offline = p("off", "OFFLINE")
        let done = p("done", "FINISH")
        let failed = p("fail", "FAILED")
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
            ("focused idle beats the first", [idle, offline], "off", "off"),
            ("nothing going on: the first", [idle, offline], nil, "idle"),
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
