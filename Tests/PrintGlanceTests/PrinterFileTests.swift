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

    func testTraysCarryEachSpoolsCodeAndSerial() throws {
        // As an X2D reported a Bambu spool in its AMS and one in its AMS HT, and an empty slot, on 23 November 2026.
        let printObj: [String: Any] = [
            "ams": ["ams": [
                ["id": "0", "tray": [
                    ["id": "3", "tray_type": "PLA", "tray_sub_brands": "PLA Matte", "tray_info_idx": "GFA01", "remain": 19,
                     "tray_color": "CBC6B8FF", "tray_id_name": "A01-W3", "tray_uuid": "c193000000000000000000000000dfef",
                     "tag_uid": "1A5D000000000100"],
                    ["id": "0", "tray_type": "PLA", "remain": 50, "tray_color": "FF0000FF",
                     "tray_id_name": "", "tray_uuid": "00000000000000000000000000000000"],
                ]],
                ["id": "128", "tray": [
                    ["id": "0", "tray_type": "PLA", "tray_sub_brands": "PLA Matte", "tray_info_idx": "GFA01", "remain": -1,
                     "tray_color": "0078BFFF", "tray_id_name": "A01-B3", "tray_uuid": "826B000000000000000000000000173F"],
                ]],
            ]],
        ]
        let trays = BambuPrint.trays(printObj)
        XCTAssertEqual(trays.map(\.code), ["A01-W3", nil, "A01-B3"])
        XCTAssertEqual(trays.map(\.spool), ["C193000000000000000000000000DFEF", nil, "826B000000000000000000000000173F"],
                       "zeros are a spool without a tag")
        var printer = row("IDLE")
        printer.trays = trays
        let entry = try XCTUnwrap(PrinterFile.make(doc: PrintDoc(v: 1, printers: [printer]), reports: [:], history: [], now: now).printers.first)
        XCTAssertEqual(entry.trays?.first, PrinterFile.Tray(slot: "A4", filament: "PLA Matte", color: "CBC6B8FF", remain: 19,
                                                           code: "A01-W3", spool: "C193000000000000000000000000DFEF"))
        XCTAssertEqual(entry.trays?.last?.slot, "HT-A")
        XCTAssertEqual(entry.trays?.last?.spool, "826B000000000000000000000000173F")
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
        try PrinterFile.make(doc: doc, reports: [:], history: [], now: now).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"state\":\"Printing\""))
        XCTAssertFalse(text.lowercased().contains("access"))
        XCTAssertFalse(text.contains("192.0.2."))
    }

    /// The folder can go while the app runs. Each file makes it again rather than failing for good.
    func testSavingMakesAMissingFolder() throws {
        let gone = scratchDirectory().appendingPathComponent("PrintGlance", isDirectory: true)
        try PrinterFile.make(doc: PrintDoc(v: 1, printers: [row("IDLE")]), reports: [:], history: [], now: now)
            .save(to: gone.appendingPathComponent(PrinterFile.fileName))
        try FileManager.default.removeItem(at: gone)
        try JobLog(rows: [JobLogRow(serial: "s", name: "Voyager", jobId: "t1", startAt: now)])
            .save(to: gone.appendingPathComponent("jobs.json"))
        XCTAssertEqual(JobLog.load(from: gone.appendingPathComponent("jobs.json")).rows.map(\.jobId), ["t1"])
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

    // MARK: - A launch that reaches no printer

    private let a1 = PrinterSettings(ip: "192.0.2.12", serial: "0309CA471800789", accessCode: "a1-code1", name: "A1 mini")

    private func entries(_ h: ModelHarness) throws -> [[String: Any]] {
        let data = try Data(contentsOf: PrinterFile.url(besideHistory: h.jobsURL))
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(file["printers"] as? [[String: Any]])
    }

    /// A write replaces the file, so a new file number means it was written.
    private func fileNumber(_ url: URL) throws -> NSNumber? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    }

    /// As seen in the field: two printers printing, then a copy that reaches none of them (another Wi-Fi, Local
    /// Network not allowed). The last launch's Printing rows stood for days, which read like a live app.
    func testALaunchThatReachesNoPrinterSaysEachIsOffline() async throws {
        let h = ModelHarness(self)
        let links = h.add(.x2d(), .p1s(), a1)
        links[0].accept()
        links[1].accept()
        links[0].report(Report.running(percent: 16, minutesLeft: 90))
        links[1].report(Report.running(percent: 19, minutesLeft: 88, job: "Gears", task: "t9"))
        let url = PrinterFile.url(besideHistory: h.jobsURL)
        let printing = try Data(contentsOf: url)
        XCTAssertEqual(try entries(h).map { $0["state"] as? String }, ["Printing", "Printing", "Offline"])
        let history = try Data(contentsOf: h.jobsURL)
        let posted = h.notifications.posted.count

        // A new copy dials all three, as `start()` does.
        h.relaunch(connectTimeout: .milliseconds(100))
        h.model.saveSettings(h.model.settings)
        XCTAssertEqual(h.model.content.result, .connecting)
        XCTAssertEqual(try Data(contentsOf: url), printing, "left alone while the printers may still answer")

        let down = await eventually { h.model.content.result == .feedDown }
        XCTAssertTrue(down, h.logText)
        let offline = try entries(h)
        XCTAssertEqual(offline.map { $0["name"] as? String }, ["X2D", "P1S", "A1 mini"])
        XCTAssertEqual(offline.map { $0["id"] as? String }, [PrinterSettings.x2d().serial, PrinterSettings.p1s().serial, a1.serial])
        for entry in offline {
            XCTAssertEqual(Set(entry.keys), ["id", "name", "state", "code", "trays"],
                           "like a printer that never answered: no percent, time left, finish time, job, or start")
            XCTAssertEqual(entry["state"] as? String, "Offline")
            XCTAssertEqual(entry["code"] as? String, "OFFLINE")
            XCTAssertEqual((entry["trays"] as? [Any])?.count, 0)
        }
        XCTAssertEqual(try Data(contentsOf: h.jobsURL), history, "History doesn't see a printer it hasn't heard from")
        XCTAssertEqual(h.notifications.posted.count, posted, "no Lost connection either")

        // Later passes with the same rows leave the file alone.
        let written = try fileNumber(url)
        for serial in [PrinterSettings.x2d().serial, PrinterSettings.p1s().serial, a1.serial] {
            try XCTUnwrap(h.printers.latest(serial)).drop("closed")
        }
        XCTAssertEqual(h.model.content.result, .feedDown)
        XCTAssertEqual(try fileNumber(url), written, "not written again")

        // A printer that answers gets its row back.
        let x2d = try XCTUnwrap(h.printers.latest(PrinterSettings.x2d().serial))
        x2d.accept()
        x2d.report(Report.running(percent: 17, minutesLeft: 89))
        let back = try entries(h)
        XCTAssertEqual(back.map { $0["state"] as? String }, ["Printing", "Offline", "Offline"])
        XCTAssertEqual(back[0]["percent"] as? Int, 17)
        XCTAssertNotNil(back[0]["finishAt"])
        XCTAssertNotNil(back[0]["startedAt"], "History's print from before the relaunch")
    }

    /// One printer failing while another may still answer: the file waits, so the other doesn't read Printing,
    /// Offline, Printing.
    func testAFailureWhileAnotherPrinterConnectsLeavesTheFile() throws {
        let h = ModelHarness(self)
        let links = h.add(.x2d(), .p1s())
        links.forEach { $0.accept() }
        links[0].report(Report.running(percent: 16, minutesLeft: 90))
        links[1].report(Report.state("IDLE"))
        let url = PrinterFile.url(besideHistory: h.jobsURL)
        let before = try Data(contentsOf: url)

        h.relaunch()
        h.model.saveSettings(h.model.settings)
        let x2d = try XCTUnwrap(h.printers.latest(PrinterSettings.x2d().serial))
        try XCTUnwrap(h.printers.latest(PrinterSettings.p1s().serial)).drop("ECONNREFUSED")
        x2d.accept()
        XCTAssertEqual(h.model.content.result, .connecting)
        XCTAssertEqual(try Data(contentsOf: url), before)

        x2d.report(Report.running(percent: 17, minutesLeft: 89))
        XCTAssertEqual(try entries(h).map { $0["state"] as? String }, ["Printing", "Offline"])
    }

    // MARK: - Writes that fail

    func testAFailedWriteIsLoggedOnceAndTriedAgain() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(.x2d()).first)
        link.answer(Report.state("IDLE"))
        let url = PrinterFile.url(besideHistory: h.jobsURL)
        let idle = try Data(contentsOf: url)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.dir.path) }

        link.report(Report.ams(remain: 50))
        link.report(Report.ams(remain: 50))
        XCTAssertEqual(try Data(contentsOf: url), idle, "the folder can't be written")
        XCTAssertEqual(h.logText.components(separatedBy: "printers.json: ").count - 1, 1, "once, not every pass")
        XCTAssertFalse(h.logText.contains(PrinterSettings.x2d().accessCode))

        // The same rows again: written now, though nothing changed since the failed write.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.dir.path)
        link.report(Report.ams(remain: 50))
        let trays = try XCTUnwrap(try entries(h).first?["trays"] as? [[String: Any]])
        XCTAssertEqual(trays.first?["remain"] as? Int, 50)

        // A new failure is logged again.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.dir.path)
        link.report(Report.ams(remain: 40))
        XCTAssertEqual(h.logText.components(separatedBy: "printers.json: ").count - 1, 2)
    }

    func testAHistoryWriteThatFailsIsLoggedOnceAndTriedAgain() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(.x2d()).first)
        link.accept()
        link.report(Report.running())
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.dir.path) }

        link.report(Report.state("FINISH"))
        link.report(Report.state("FINISH"))
        XCTAssertEqual(JobLog.load(from: h.jobsURL).rows.map(\.outcome), [nil], "still open on disk")
        XCTAssertEqual(h.logText.components(separatedBy: "jobs.json: ").count - 1, 1, "once, not every pass")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.dir.path)
        link.report(Report.state("FINISH"))
        XCTAssertEqual(JobLog.load(from: h.jobsURL).rows.map(\.outcome), [JobLog.outcomeOK])
    }

    /// The Application Support folder deleted while the app runs. It used to be made only at launch.
    func testAFolderThatWentMissingIsMadeAgain() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(.x2d()).first)
        link.accept()
        link.report(Report.running(percent: 16, minutesLeft: 90))
        try FileManager.default.removeItem(at: h.dir)

        link.report(Report.state("FINISH"))
        XCTAssertEqual(JobLog.load(from: h.jobsURL).rows.map(\.outcome), [JobLog.outcomeOK])
        XCTAssertEqual(try entries(h).first?["state"] as? String, "Finished")
        XCTAssertFalse(h.logText.contains(".json: "), "nothing failed")
    }
}
