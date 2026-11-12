import Foundation
import XCTest
@testable import PrintGlance

final class PrinterFileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ state: String, id: String = "20P9AJ5B0700123", jobId: String? = "t1") -> Printer {
        Printer(id: id, name: "Voyager", state: state, percent: 52, remainingS: 5_040, job: "plate_2",
                layer: 18, layerTotal: 29, eta: "16:25", filament: "PLA Matte", filamentRemain: 80, jobId: jobId)
    }

    func testPlateComesFromTheFileName() {
        XCTAssertEqual(PrinterFile.plateNumber("/data/Metadata/plate_3.gcode"), 3)
        XCTAssertEqual(PrinterFile.plateNumber("Metadata/plate_12.gcode"), 12)
        XCTAssertNil(PrinterFile.plateNumber("/sdcard/Benchy.gcode.3mf"))
        XCTAssertNil(PrinterFile.plateNumber(nil))
    }

    func testProjectIsTheSlicerNameAsSent() {
        XCTAssertEqual(PrinterFile.projectName(["subtask_name": "  Dino Eggs 0.2mm layer "]), "Dino Eggs 0.2mm layer")
        XCTAssertNil(PrinterFile.projectName(["subtask_name": " "]))
        XCTAssertNil(PrinterFile.projectName([:]))
    }

    func testPrintingEntryCarriesFinishTimeProjectAndTrays() throws {
        var printing = row("RUNNING")
        printing.trays = [AMSTray(id: "0", name: "PLA Matte", remain: 80, color: "FF6A13FF", label: "A1", unit: "A")]
        let doc = PrintDoc(v: 1, printers: [printing])
        let report: [String: Any] = ["subtask_name": "Dino Eggs", "gcode_file": "/data/Metadata/plate_2.gcode"]
        let started = now.addingTimeInterval(-3_600)
        let history = [JobLogRow(serial: printing.id, name: "Voyager", jobId: "t1", startAt: started)]

        let entry = try XCTUnwrap(PrinterFile.make(doc: doc, reports: [printing.id: report], history: history, now: now).printers.first)

        XCTAssertEqual(entry.state, "Printing")
        XCTAssertEqual(entry.code, "RUNNING")
        XCTAssertEqual(entry.project, "Dino Eggs")
        XCTAssertEqual(entry.plate, 2)
        XCTAssertEqual(entry.startedAt, started)
        XCTAssertNil(entry.endedAt)
        XCTAssertEqual(entry.finishAt, now.addingTimeInterval(5_040), "remaining time from now, to the minute")
        XCTAssertEqual(entry.trays, [PrinterFile.Tray(slot: "A1", filament: "PLA Matte", color: "FF6A13FF", remain: 80)])
        XCTAssertNil(entry.reason)
        XCTAssertNil(entry.errorCodes)
    }

    func testPausedEntrySaysWhy() throws {
        var paused = row("PAUSE")
        paused.printError = "0700-8010"
        let entry = try XCTUnwrap(PrinterFile.make(doc: PrintDoc(v: 1, printers: [paused]), reports: [:], history: [], now: now).printers.first)
        XCTAssertEqual(entry.state, "Paused")
        XCTAssertEqual(entry.errorCodes, ["0700-8010"])
        XCTAssertEqual(entry.reason, GlanceContent.errorReason(code: "0700-8010"))
        XCTAssertNotNil(entry.finishAt, "a paused print still has time left")
    }

    func testFinishedEntryHasNoFinishTimeButKeepsWhenItEnded() throws {
        let finished = row("FINISH")
        let ended = now.addingTimeInterval(-600)
        let history = [JobLogRow(serial: finished.id, name: "Voyager", jobId: "t1", startAt: ended.addingTimeInterval(-7_200),
                                 endedAt: ended, outcome: JobLog.outcomeOK)]
        let entry = try XCTUnwrap(PrinterFile.make(doc: PrintDoc(v: 1, printers: [finished]), reports: [:], history: history, now: now).printers.first)
        XCTAssertEqual(entry.state, "Finished")
        XCTAssertNil(entry.finishAt)
        XCTAssertEqual(entry.endedAt, ended)
    }

    func testHistoryOfAnotherPrintIsNotUsed() throws {
        let printing = row("RUNNING", jobId: "t2")
        let history = [JobLogRow(serial: printing.id, name: "Voyager", jobId: "t1", startAt: now)]
        let entry = try XCTUnwrap(PrinterFile.make(doc: PrintDoc(v: 1, printers: [printing]), reports: [:], history: history, now: now).printers.first)
        XCTAssertNil(entry.startedAt)
    }

    func testFileHasNoAccessCodeOrAddress() throws {
        let doc = PrintDoc(v: 1, printers: [row("RUNNING")])
        let url = scratchDirectory().appendingPathComponent(PrinterFile.fileName)
        PrinterFile.make(doc: doc, reports: [:], history: [], now: now).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"state\":\"Printing\""))
        XCTAssertFalse(text.lowercased().contains("access"))
        XCTAssertFalse(text.contains("192.0.2."))
    }
}

@MainActor
final class PrinterFileModelTests: XCTestCase {
    func testReportWritesThePrintersFileBesideHistory() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(PrinterSettings.x2d()).first)
        link.accept()
        link.report(["gcode_state": "RUNNING", "task_id": "t1", "subtask_name": "Dino Eggs",
                     "gcode_file": "/data/Metadata/plate_2.gcode", "mc_percent": 10, "mc_remaining_time": 90,
                     "layer_num": 3, "total_layer_num": 100])

        let url = PrinterFile.url(besideHistory: h.jobsURL)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(PrinterFile.self, from: Data(contentsOf: url))
        let entry = try XCTUnwrap(file.printers.first)
        XCTAssertEqual(entry.project, "Dino Eggs")
        XCTAssertEqual(entry.plate, 2)
        XCTAssertEqual(entry.state, "Printing")
        XCTAssertNotNil(entry.startedAt, "history opened a row for it")
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(PrinterSettings.x2d().accessCode))
    }

    func testRemovingEveryPrinterEmptiesTheFile() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(PrinterSettings.x2d()).first)
        link.accept()
        link.report(["gcode_state": "IDLE"])
        h.model.saveSettings(.empty)
        let file = try JSONDecoder().decode(PrinterFile.self, from: Data(contentsOf: PrinterFile.url(besideHistory: h.jobsURL)))
        XCTAssertTrue(file.printers.isEmpty)
    }
}
