import XCTest
@testable import PrintGlance

final class OverrunTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)  // 14:13:20 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func row(_ state: String, minutesLeft: Int? = nil, job: String = "t1", percent: Int = 50) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: state, percent: percent, jobId: job)
        p.remainingS = minutesLeft.map { $0 * 60 }
        return p
    }

    /// Feeds one report `seconds` after `t0` and returns the row as the card would get it.
    @discardableResult
    private func at(_ seconds: Double, _ o: inout Overrun, _ row: Printer) -> Printer {
        var row = row
        o.observe(&row, now: t0.addingTimeInterval(seconds), calendar: utc, locale: Locale(identifier: "en_GB"))
        return row
    }

    /// A print whose last time left was 1 minute at `lastPromise` seconds, and which reported
    /// Finished `late` seconds after that minute was up.
    private func finish(_ o: inout Overrun, late: Double, job: String = "t1", lastPromise: Double = 0) {
        at(lastPromise - 60, &o, row("RUNNING", minutesLeft: 2, job: job))
        at(lastPromise, &o, row("RUNNING", minutesLeft: 1, job: job))
        at(lastPromise + 40, &o, row("RUNNING", minutesLeft: 0, job: job, percent: 99))
        at(lastPromise + 60 + late, &o, row("FINISH", minutesLeft: 0, job: job, percent: 100))
    }

    /// Voyager on 2026-11-10: 1 minute left at 14:48:39, 0 at 14:49:40, 100% at 14:51:21,
    /// Finished at 14:54:43.
    func testAFinishTeachesHowLateThePrinterRuns() {
        var o = Overrun()
        at(0, &o, row("RUNNING", minutesLeft: 1, percent: 97))
        at(61, &o, row("RUNNING", minutesLeft: 0, percent: 98))
        at(162, &o, row("RUNNING", minutesLeft: 0, percent: 100))
        XCTAssertEqual(o.lateBy("x2d"), 0)
        at(364, &o, row("FINISH", minutesLeft: 0, percent: 100))
        XCTAssertEqual(o.lateBy("x2d"), 304, "Finished 364 s after a promise of 60")
    }

    func testTheNextPrintGetsItAdded() {
        var o = Overrun()
        finish(&o, late: 300)
        let next = at(1000, &o, row("RUNNING", minutesLeft: 60, job: "t2"))
        XCTAssertEqual(next.remainingS, 65 * 60)
        XCTAssertEqual(next.eta, "15:35", "14:30 and 65 minutes")
        XCTAssertEqual(at(1000, &o, row("PREPARE", minutesLeft: 60, job: "t2")).remainingS, 65 * 60)
        XCTAssertEqual(at(1000, &o, row("PAUSE", minutesLeft: 60, job: "t2")).remainingS, 65 * 60)
        XCTAssertEqual(at(1000, &o, row("OFFLINE", minutesLeft: 60, job: "t2")).remainingS, 65 * 60)
    }

    func testAPrinterNeverSeenFinishingIsLeftAlone() {
        var o = Overrun()
        let plain = row("RUNNING", minutesLeft: 60)
        XCTAssertEqual(at(0, &o, plain), plain)
        var other = plain
        other.id = "p1s"
        finish(&o, late: 300)
        XCTAssertEqual(at(1000, &o, other), other, "each printer learns its own")
    }

    /// The time left reads 0 for the last minutes. The row then counts down to one fixed finish.
    func testCountsDownOnceTheTimeLeftRunsOut() {
        var o = Overrun()
        finish(&o, late: 300)
        at(1000, &o, row("RUNNING", minutesLeft: 1, job: "t2"))
        // Promised 14:31:00; five minutes late is 14:36:00.
        let early = at(1070, &o, row("RUNNING", minutesLeft: 0, job: "t2", percent: 99))
        XCTAssertEqual(early.remainingS, 5 * 60, "4m 50s rounds up")
        XCTAssertEqual(early.eta, "14:36")
        let later = at(1200, &o, row("RUNNING", minutesLeft: 0, job: "t2", percent: 100))
        XCTAssertEqual(later.remainingS, 3 * 60)
        XCTAssertEqual(later.eta, "14:36", "the finish time doesn't move")
        let overdue = at(1400, &o, row("RUNNING", minutesLeft: 0, job: "t2", percent: 100))
        XCTAssertEqual(overdue.remainingS, 0, "past it: no time, as before")
        XCTAssertNil(overdue.eta)
    }

    func testTheMiddleOfTheLastFivePrintsCounts() {
        var o = Overrun()
        for (i, late) in [280.0, 300, 900, 310, 290].enumerated() {
            finish(&o, late: late, job: "t\(i)", lastPromise: Double(i) * 2000)
        }
        XCTAssertEqual(o.lateBy("x2d"), 300, "one print that sat for 15 minutes doesn't move it")
        finish(&o, late: 200, job: "t5", lastPromise: 10_000)
        finish(&o, late: 200, job: "t6", lastPromise: 12_000)
        XCTAssertEqual(o.late["x2d"], [900, 310, 290, 200, 200])
        XCTAssertEqual(o.lateBy("x2d"), 290)
        finish(&o, late: 240, job: "t7", lastPromise: 14_000)
        finish(&o, late: 260, job: "t8", lastPromise: 16_000)
        XCTAssertEqual(o.late["x2d"], [290, 200, 200, 240, 260])
        o.late["x2d"] = [240, 300]
        XCTAssertEqual(o.lateBy("x2d"), 270, "two prints: halfway")
    }

    func testWhatTeachesNothing() {
        var o = Overrun()
        finish(&o, late: 901)
        XCTAssertEqual(o.late, [:], "over 15 minutes: the app missed the end")
        finish(&o, late: -90)
        XCTAssertEqual(o.late, [:], "finished before its last promise")

        at(0, &o, row("RUNNING", minutesLeft: 1))
        at(30, &o, row("PAUSE", minutesLeft: 1))
        at(600, &o, row("RUNNING", minutesLeft: 0))
        at(700, &o, row("FINISH", minutesLeft: 0))
        XCTAssertEqual(o.late, [:], "paused after its last promise")

        at(0, &o, row("RUNNING", minutesLeft: 1))
        at(200, &o, row("FAILED", minutesLeft: 0))
        at(300, &o, row("FINISH", minutesLeft: 0))
        XCTAssertEqual(o.late, [:], "failed")

        at(0, &o, row("RUNNING", minutesLeft: 1, job: "t1"))
        at(300, &o, row("FINISH", minutesLeft: 0, job: "t2"))
        XCTAssertEqual(o.late, [:], "another job's finish")

        at(300, &o, row("FINISH", minutesLeft: 0))
        XCTAssertEqual(o.late, [:], "never seen printing")
    }

    func testAPromiseAfterAPauseCountsAgain() {
        var o = Overrun()
        at(0, &o, row("RUNNING", minutesLeft: 2))
        at(30, &o, row("PAUSE", minutesLeft: 2))
        at(600, &o, row("RUNNING", minutesLeft: 2))
        at(660, &o, row("RUNNING", minutesLeft: 1))
        at(1020, &o, row("FINISH", minutesLeft: 0))
        XCTAssertEqual(o.late["x2d"], [300])
    }

    func testOnlyWhatWasLearnedIsSaved() throws {
        var o = Overrun()
        finish(&o, late: 300)
        at(1000, &o, row("RUNNING", minutesLeft: 60, job: "t2"))
        XCTAssertNotNil(o.promises["x2d"])

        let d = scratchDefaults()
        o.save(d)
        let restored = Overrun.load(d)
        XCTAssertEqual(restored.late, ["x2d": [300]])
        XCTAssertEqual(restored.promises, [:])
        XCTAssertEqual(String(data: try XCTUnwrap(d.data(forKey: Overrun.defaultsKey)), encoding: .utf8), #"{"late":{"x2d":[300]}}"#)
    }
}
