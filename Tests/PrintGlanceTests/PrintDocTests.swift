import Foundation
import XCTest
@testable import PrintGlance

final class PrintDocTests: XCTestCase {
    func testRunningFixtureDecodesAndStrip() throws {
        let doc = try load("print-running")
        XCTAssertEqual(doc.v, 1)
        let row = try XCTUnwrap(doc.focusRow())
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
        XCTAssertEqual(strip.title, " 16%  18:30")
        XCTAssertTrue(strip.accessibilityLabel.contains("16 percent"))
        XCTAssertTrue(strip.accessibilityLabel.contains("18:30"))
        XCTAssertEqual(GlanceContent.hero(row), "18:30")
        XCTAssertEqual(GlanceContent.remainingLine(row), "4h 43m left")
        XCTAssertEqual(GlanceContent.layerLine(row), "Layer 32 / 230")
        XCTAssertEqual(GlanceContent.filamentLine(row), "PLA  42%")
        XCTAssertEqual(GlanceContent(result: .doc(doc)).pollInterval, 5)
    }

    func testIdleNullsDecode() throws {
        let doc = try load("print-idle")
        let row = try XCTUnwrap(doc.focusRow())
        XCTAssertEqual(row.state, "IDLE")
        XCTAssertNil(row.percent)
        XCTAssertNil(row.remainingS)
        XCTAssertNil(row.job)
        XCTAssertNil(row.eta)
        XCTAssertNil(row.layer)

        let strip = GlanceContent.strip(row: row)
        XCTAssertEqual(strip.systemImage, "printer")
        XCTAssertEqual(strip.title, "")
        XCTAssertEqual(GlanceContent.hero(row), "Idle")
        XCTAssertEqual(GlanceContent(result: .doc(doc)).pollInterval, 60)
    }

    func testEmptyPrintersIsSlashNotSubscript() throws {
        let data = Data(#"{"v":1,"updated_at":null,"focus_id":null,"printers":[]}"#.utf8)
        let result = PrintFeed.interpret(status: 200, data: data)
        guard case let .doc(doc) = result else {
            XCTFail("expected doc, got \(result)")
            return
        }
        XCTAssertNil(doc.focusRow())
        let strip = GlanceContent.strip(result)
        XCTAssertEqual(strip.systemImage, "printer.slash")
        XCTAssertEqual(strip.title, "")
    }

    func testUnauthorizedBodyIsNotV1() {
        let data = Data(#"{"error":"unauthorized"}"#.utf8)
        XCTAssertEqual(PrintFeed.interpret(status: 401, data: data), .unauthorized)
        let strip = GlanceContent.strip(.unauthorized)
        XCTAssertEqual(strip.systemImage, "printer.slash")
        XCTAssertEqual(GlanceContent(result: .unauthorized).footer, "Token required")
    }

    func testNotFoundBodyIsNotV1() {
        let data = Data(#"{"error":"not found"}"#.utf8)
        XCTAssertEqual(PrintFeed.interpret(status: 404, data: data), .http(404))
    }

    func testBadJsonIsInvalidNotHttp200() {
        let garbage = Data(#"{"error":"not found"}"#.utf8)
        XCTAssertEqual(PrintFeed.interpret(status: 200, data: garbage), .invalid)
        let v2 = Data(#"{"v":2,"focus_id":null,"printers":[]}"#.utf8)
        XCTAssertEqual(PrintFeed.interpret(status: 200, data: v2), .invalid)
        XCTAssertEqual(PrintFeed.interpret(status: 200, data: Data(#"{"v":1"#.utf8)), .invalid)
        XCTAssertEqual(GlanceContent.strip(.invalid).systemImage, "printer.slash")
        XCTAssertEqual(GlanceContent(result: .invalid).pollInterval, 15)
        XCTAssertEqual(GlanceContent(result: .invalid).footer, "Bad feed")
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

    func testPollIntervals() {
        var row = Printer(id: "x2d", name: "X2D", state: "PAUSE", percent: 9)
        XCTAssertEqual(GlanceContent(result: .doc(doc(row))).pollInterval, 5)
        row.state = "FINISH"
        XCTAssertEqual(GlanceContent(result: .doc(doc(row))).pollInterval, 30)
        row.state = "FAILED"
        XCTAssertEqual(GlanceContent(result: .doc(doc(row))).pollInterval, 30)
        XCTAssertEqual(GlanceContent(result: .http(500)).pollInterval, 15)
        let empty = Data(#"{"v":1,"updated_at":null,"focus_id":null,"printers":[]}"#.utf8)
        guard case let .doc(doc) = PrintFeed.interpret(status: 200, data: empty) else {
            XCTFail("expected empty doc")
            return
        }
        XCTAssertEqual(GlanceContent(result: .doc(doc)).pollInterval, 15)
    }

    private func doc(_ row: Printer) -> PrintDoc {
        PrintDoc(v: 1, updatedAt: nil, focusId: row.id, printers: [row])
    }

    func testPauseAndFinishAndFailedStrip() {
        var pause = Printer(id: "x2d", name: "X2D", state: "PAUSE", percent: 9)
        XCTAssertEqual(GlanceContent.strip(row: pause).title, "  9%")
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "pause.fill")

        pause.state = "FINISH"
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "checkmark")
        XCTAssertEqual(GlanceContent.strip(row: pause).title, "")

        pause.state = "FAILED"
        XCTAssertEqual(GlanceContent.strip(row: pause).systemImage, "xmark")
    }

    func testPercentPaddingStableWidth() {
        XCTAssertEqual(GlanceContent.paddedPercent(9), "  9%")
        XCTAssertEqual(GlanceContent.paddedPercent(16), " 16%")
        XCTAssertEqual(GlanceContent.paddedPercent(100), "100%")
    }

    func testFeedDownFooter() {
        XCTAssertEqual(GlanceContent(result: .feedDown).footer, "Feed off")
        XCTAssertEqual(GlanceContent.strip(.feedDown).systemImage, "printer.slash")
    }

    func testNeedsSetupStrip() {
        XCTAssertEqual(GlanceContent.strip(.needsSetup).systemImage, "printer")
        XCTAssertEqual(GlanceContent(result: .needsSetup).pollInterval, 60)
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

    func testFocusPrefersRunningThenPauseThenFirst() {
        let idle = Printer(id: "a", name: "A", state: "IDLE")
        let pause = Printer(id: "b", name: "B", state: "PAUSE", percent: 9)
        let run = Printer(id: "c", name: "C", state: "RUNNING", percent: 16)
        let prepare = Printer(id: "d", name: "D", state: "PREPARE", percent: 1)
        XCTAssertEqual(
            PrintDoc(v: 1, updatedAt: nil, focusId: nil, printers: [idle, pause, run]).focusRow()?.id,
            "c"
        )
        XCTAssertEqual(
            PrintDoc(v: 1, updatedAt: nil, focusId: nil, printers: [idle, prepare, pause]).focusRow()?.id,
            "d"
        )
        XCTAssertEqual(
            PrintDoc(v: 1, updatedAt: nil, focusId: nil, printers: [idle, pause]).focusRow()?.id,
            "b"
        )
        XCTAssertEqual(
            PrintDoc(v: 1, updatedAt: nil, focusId: nil, printers: [idle]).focusRow()?.id,
            "a"
        )
        XCTAssertEqual(
            PrintDoc(v: 1, updatedAt: nil, focusId: "a", printers: [idle, run]).focusRow()?.id,
            "a"
        )
    }

    func testEmptyListIsNeedsSetup() throws {
        XCTAssertFalse(SavedPrinters.empty.isComplete)
        XCTAssertFalse(SavedPrinters(printers: [PrinterSettings.empty], focusId: nil).isComplete)
        XCTAssertEqual(GlanceContent(result: .needsSetup).footer, "Add printer")

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
        XCTAssertEqual(doc.focusRow()?.id, "aaa")
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
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // Saturday 2026-08-22 10:00 GMT
        let morning = Date(timeIntervalSince1970: 1_787_392_800)
        XCTAssertEqual(
            BambuPrint.etaHM(state: "RUNNING", remainingS: 30_600, now: morning, calendar: cal),
            "18:30"
        )
        XCTAssertEqual(
            BambuPrint.etaHM(state: "RUNNING", remainingS: 26 * 3600, now: morning, calendar: cal),
            "12:00 tomorrow"
        )
        XCTAssertEqual(
            BambuPrint.etaHM(state: "RUNNING", remainingS: 203_400, now: morning, calendar: cal),
            "18:30 Mon"
        )
        // Saturday 2026-08-22 22:00 GMT, 3h overnight
        let evening = Date(timeIntervalSince1970: 1_787_436_000)
        XCTAssertEqual(
            BambuPrint.etaHM(state: "RUNNING", remainingS: 3 * 3600, now: evening, calendar: cal),
            "01:00 tomorrow"
        )
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
