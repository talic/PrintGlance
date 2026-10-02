import Foundation
import XCTest
@testable import PrintGlance

final class JobLogTests: XCTestCase {
    func testOpenOnRunningCloseLiveFinish() {
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: t0)
        XCTAssertEqual(log.rows.count, 1)
        XCTAssertTrue(log.rows[0].isOpen)
        XCTAssertEqual(log.rows[0].startAt, t0)
        XCTAssertEqual(log.rows[0].job, "Print in Parts")

        let t1 = t0.addingTimeInterval(3600)
        log.observe(printers: [row("FINISH", jobId: "t1")], now: t1)
        XCTAssertFalse(log.rows[0].isOpen)
        XCTAssertEqual(log.rows[0].outcome, JobLog.outcomeOK)
        XCTAssertEqual(log.rows[0].endedAt, t1)
        XCTAssertEqual(
            log.occupancyEndedAt(serial: "x2d", state: "FINISH", jobId: "t1"),
            t1
        )
    }

    func testPrepareThenRunningSameJob() {
        var log = JobLog()
        log.observe(printers: [row("PREPARE", jobId: nil)], now: Date())
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: Date())
        XCTAssertEqual(log.rows.count, 1)
        XCTAssertEqual(log.rows[0].jobId, "t1")
        XCTAssertTrue(log.rows[0].isOpen)
    }

    func testPauseThenFinishIsLive() {
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: t0)
        log.observe(printers: [row("PAUSE", jobId: "t1")], now: t0.addingTimeInterval(10))
        let t1 = t0.addingTimeInterval(100)
        log.observe(printers: [row("FINISH", jobId: "t1")], now: t1)
        XCTAssertEqual(log.rows[0].endedAt, t1)
    }

    func testFailedClosesFail() {
        var log = JobLog()
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: Date())
        log.observe(printers: [row("FAILED", jobId: "t1")], now: Date())
        XCTAssertEqual(log.rows[0].outcome, JobLog.outcomeFail)
        XCTAssertNil(log.occupancyEndedAt(serial: "x2d", state: "FAILED", jobId: "t1"))
    }

    func testRelaunchAlreadyFinishWithOpenRowClosesNilEndedAt() {
        var log = JobLog()
        log.rows = [
            JobLogRow(
                serial: "x2d",
                name: "X2D",
                jobId: "t1",
                job: "Print in Parts",
                filament: "PLA",
                startAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: nil,
                outcome: nil
            ),
        ]
        log.observe(printers: [row("FINISH", jobId: "t1")], now: Date())
        XCTAssertEqual(log.rows[0].outcome, JobLog.outcomeOK)
        XCTAssertNil(log.rows[0].endedAt)
        XCTAssertNil(log.occupancyEndedAt(serial: "x2d", state: "FINISH", jobId: "t1"))
    }

    func testRelaunchAlreadyIdleWithOpenRowClosesNilEndedAt() {
        var log = JobLog()
        log.rows = [
            JobLogRow(
                serial: "x2d",
                name: "X2D",
                jobId: "t1",
                job: "Print in Parts",
                filament: nil,
                startAt: Date(),
                endedAt: nil,
                outcome: nil
            ),
        ]
        log.observe(printers: [row("IDLE", jobId: "t1", job: nil)], now: Date())
        XCTAssertEqual(log.rows[0].outcome, JobLog.outcomeOK)
        XCTAssertNil(log.rows[0].endedAt)
        XCTAssertNil(log.occupancyEndedAt(serial: "x2d", state: "IDLE", jobId: "t1"))
    }

    func testRelaunchFinishUsesPersistedEndedAt() {
        let ended = Date(timeIntervalSince1970: 1_700_000_100)
        var log = JobLog()
        log.rows = [
            JobLogRow(
                serial: "x2d",
                name: "X2D",
                jobId: "t1",
                job: "Print in Parts",
                filament: "PLA",
                startAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: ended,
                outcome: JobLog.outcomeOK
            ),
        ]
        log.observe(printers: [row("FINISH", jobId: "t1")], now: Date())
        XCTAssertEqual(log.rows.count, 1)
        XCTAssertEqual(
            log.occupancyEndedAt(serial: "x2d", state: "FINISH", jobId: "t1"),
            ended
        )
    }

    func testCap50DropsOldestClosed() {
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<50 {
            let id = "t\(i)"
            log.observe(printers: [row("RUNNING", jobId: id)], now: t0.addingTimeInterval(Double(i)))
            log.observe(
                printers: [row("FINISH", jobId: id)],
                now: t0.addingTimeInterval(Double(i) + 0.5)
            )
        }
        XCTAssertEqual(log.rows.count, 50)
        log.observe(printers: [row("RUNNING", jobId: "t-new")], now: t0.addingTimeInterval(100))
        log.observe(printers: [row("FINISH", jobId: "t-new")], now: t0.addingTimeInterval(101))
        XCTAssertEqual(log.rows.count, 50)
        XCTAssertEqual(log.rows.first?.jobId, "t-new")
        XCTAssertFalse(log.rows.contains { $0.jobId == "t0" })
    }

    func testCsvHasDurationMinutes() {
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: t0)
        log.observe(printers: [row("FINISH", jobId: "t1")], now: t0.addingTimeInterval(1800))
        let csv = log.csv()
        XCTAssertTrue(csv.contains("started,ended,duration_min,printer,job,filament,outcome"))
        XCTAssertTrue(csv.contains("30"))
        XCTAssertTrue(csv.contains("ok"))
    }

    func testOccupancyClockAdvancesWithoutStateChange() {
        let ended = Date(timeIntervalSince1970: 1_700_000_000)
        var printer = Printer(id: "x2d", name: "X2D", state: "FINISH")
        printer.jobId = "t1"
        let later = ended.addingTimeInterval(40 * 60)
        let strip0 = GlanceContent.strip(row: printer, occupancyEndedAt: ended, now: ended)
        let strip1 = GlanceContent.strip(row: printer, occupancyEndedAt: ended, now: later)
        XCTAssertEqual(strip0.title, "0m ago")
        XCTAssertEqual(strip1.title, "40m ago")
        XCTAssertEqual(strip0.systemImage, "checkmark")
        XCTAssertEqual(
            GlanceContent.hero(printer, occupancyEndedAt: ended, now: later),
            "40m ago"
        )
        XCTAssertNil(GlanceContent.hero(printer))
        XCTAssertEqual(GlanceContent.strip(row: printer).title, "")
    }

    func testHistoryCaption() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let gb = Locale(identifier: "en_GB")
        // Saturday 2026-08-22 10:00 GMT; the print started 14:02 the day before.
        let now = Date(timeIntervalSince1970: 1_787_392_800)
        let start = Date(timeIntervalSince1970: 1_787_320_920)
        var row = JobLogRow(
            serial: "x2d", name: "X2D", jobId: "t1", job: "Benchy", filament: nil,
            startAt: start, endedAt: start + 283 * 60, outcome: JobLog.outcomeOK
        )
        func caption(_ many: Bool = false) -> String {
            GlanceContent.historyCaption(row, showPrinter: many, now: now, calendar: cal, locale: gb)
        }
        XCTAssertEqual(caption(), "14:02 yesterday · 4h 43m · Finished")
        XCTAssertEqual(caption(true), "X2D · 14:02 yesterday · 4h 43m · Finished")
        row.outcome = JobLog.outcomeFail
        XCTAssertEqual(caption(), "14:02 yesterday · 4h 43m · Failed")
        row.endedAt = nil
        XCTAssertEqual(caption(), "14:02 yesterday · Failed", "no duration when the end wasn't seen")
        row.outcome = nil
        XCTAssertEqual(caption(), "14:02 yesterday · Printing")
        row.startAt = now - 10 * 86_400
        XCTAssertEqual(caption(), "12 Aug · Printing")
    }

    func testRoundTripFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: t0)
        log.observe(printers: [row("FINISH", jobId: "t1")], now: t0.addingTimeInterval(60))
        log.save(to: url)
        let loaded = JobLog.load(from: url)
        XCTAssertEqual(loaded.rows.count, 1)
        XCTAssertEqual(loaded.rows[0].jobId, "t1")
        XCTAssertEqual(loaded.rows[0].outcome, JobLog.outcomeOK)
        XCTAssertEqual(loaded.rows[0].endedAt, t0.addingTimeInterval(60))
    }

    func testClearForgetsEndedPrintsAndKeepsTheOneRunning() {
        var log = JobLog()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        log.observe(printers: [row("RUNNING", jobId: "t1")], now: t0)
        log.observe(printers: [row("FAILED", jobId: "t1")], now: t0 + 60)
        log.observe(printers: [row("RUNNING", jobId: "t2")], now: t0 + 120)
        log.observe(printers: [row("FINISH", jobId: "t2")], now: t0 + 180)
        var other = row("RUNNING", jobId: "p9")
        other.id = "p1s"
        log.observe(printers: [other], now: t0 + 200)
        XCTAssertEqual(log.rows.count, 3)

        log.clearEnded()
        XCTAssertEqual(log.rows.map(\.jobId), ["p9"])
        XCTAssertNil(log.occupancyEndedAt(serial: "x2d", state: "FINISH", jobId: "t2"), "no \"40m ago\" left to show")

        other.state = "FINISH"
        log.observe(printers: [other], now: t0 + 900)
        XCTAssertEqual(log.rows.first?.startAt, t0 + 200, "the running print keeps its real start")
        XCTAssertEqual(log.rows.first?.endedAt, t0 + 900)
    }

    func testClearHistoryMessage() {
        XCTAssertEqual(GlanceContent.clearHistoryMessage(cleared: 12, running: 0),
                       "PrintGlance forgets the 12 prints saved on this Mac. You can't undo this.")
        XCTAssertEqual(GlanceContent.clearHistoryMessage(cleared: 1, running: 1),
                       "PrintGlance forgets the print saved on this Mac. You can't undo this. The print in progress stays.")
        XCTAssertTrue(GlanceContent.clearHistoryMessage(cleared: 3, running: 2).hasSuffix(" The prints in progress stay."))
    }

    private func row(_ state: String, jobId: String?, job: String? = "Print in Parts") -> Printer {
        Printer(id: "x2d", name: "X2D", state: state, percent: 16, job: job, jobId: jobId)
    }
}
