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

    func testRemainingLengthRoundTrip() {
        for n in [0, 1, 127, 128, 16383] {
            let encoded = MQTT311Client.encodeRemainingLength(n)
            var packet = Data([0x10])
            packet.append(encoded)
            packet.append(Data(repeating: 0, count: n))
            let decoded = MQTT311Client.decodeRemainingLength([UInt8](packet), start: 1)
            XCTAssertEqual(decoded?.0, n, "n=\(n)")
        }
    }

    private func load(_ name: String) throws -> PrintDoc {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONCoding.decoder.decode(PrintDoc.self, from: Data(contentsOf: url))
    }
}

extension Printer {
    init(id: String, name: String, state: String, percent: Int? = nil) {
        self.init(
            id: id,
            name: name,
            state: state,
            percent: percent,
            remainingS: nil,
            job: nil,
            layer: nil,
            layerTotal: nil,
            eta: nil,
            filament: nil,
            filamentRemain: nil
        )
    }
}
