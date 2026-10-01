import XCTest
@testable import PrintGlance

final class RunoutTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 14:13:20 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// One spool at 20% that loses a point every 2% of progress from 10%, so it reads 0 at 50%.
    /// Readings land on every whole percent, like `mc_percent`.
    private func steady(to end: Int, _ tracker: inout RunoutTracker, extra: [AMSTray] = []) -> Runout? {
        var last: Runout?
        for p in 10...end {
            last = tracker.observe(row(p, 20 - (p - 10) / 2, extra: extra), now: now, calendar: utc, locale: Locale(identifier: "en_GB"))
        }
        return last
    }

    private func row(
        _ percent: Int,
        _ remain: Int?,
        state: String = "RUNNING",
        layer: Int = 5,
        job: String = "t1",
        name: String = "PLA Matte",
        extra: [AMSTray] = []
    ) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: state, percent: percent, jobId: job)
        p.layer = layer
        p.remainingS = (100 - percent) * 100
        p.trays = [AMSTray(id: "1", name: name, remain: remain, color: "F5C6A0FF", label: "A2", unit: "A")] + extra
        return p
    }

    func testSteadyUseLandsJustBeforeEmpty() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(to: 30, &t))
        // 9 drops over 18% of progress from 11.5%: empty at 49.5%, half a step early on purpose.
        XCTAssertEqual(r.percent, 49)
        // 70% left takes 7000 s, so 19.5% more is 1950 s: 14:45:50, rounded to 14:45.
        XCTAssertEqual(r.at, "14:45")
        XCTAssertEqual(r.tray, "A2")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 14:45.")
    }

    func testNeedsEnoughDropsAndProgress() {
        var a = RunoutTracker()
        XCTAssertNil(steady(to: 15, &a), "drops at 11.5 and 13.5: one step of rate")
        var b = RunoutTracker()
        XCTAssertNil(steady(to: 17, &b), "drops at 11.5, 13.5, 15.5: only 4% of progress apart")
        var c = RunoutTracker()
        XCTAssertNotNil(steady(to: 18, &c))
    }

    func testEnoughFilamentShowsNothing() {
        var t = RunoutTracker()
        var last: Runout?
        for p in 10...40 {
            last = t.observe(row(p, 80 - (p - 10) / 2))
        }
        XCTAssertNil(last, "runs out at 169%")
    }

    func testWobbleIsIgnoredAndSwapStartsOver() {
        var t = RunoutTracker()
        XCTAssertNotNil(steady(to: 30, &t))
        XCTAssertNotNil(t.observe(row(31, 11)), "a one-point rise is the AMS estimate wobbling")
        XCTAssertNil(t.observe(row(32, 100)), "a fresh spool")
        XCTAssertNil(t.observe(row(33, 99, name: "PETG")), "another filament")
    }

    func testStartSequenceAndPausesDontCount() {
        var t = RunoutTracker()
        XCTAssertNil(t.observe(row(0, 23, state: "PREPARE", layer: 0)))
        // Purging at 0% progress takes 3 points. Counted, the rate would put the runout at 56%.
        for remain in [22, 21, 20] {
            XCTAssertNil(t.observe(row(0, remain, layer: 0)))
        }
        XCTAssertEqual(steady(to: 30, &t)?.percent, 49)

        let paused = t.observe(row(30, 10, state: "PAUSE"))
        XCTAssertEqual(paused?.percent, 49)
        XCTAssertNil(paused?.at)
        XCTAssertEqual(paused.map(GlanceContent.runoutLine), "PLA Matte in A2 runs out at about 49%.")
    }

    func testBackupSlotAndSoon() throws {
        var t = RunoutTracker()
        let twin = AMSTray(id: "2", name: "PLA Matte", remain: nil, color: "F5C6A0FF", label: "A3", unit: "A")
        let other = AMSTray(id: "3", name: "PLA Matte", remain: nil, color: "000000FF", label: "A4", unit: "A")
        let r = try XCTUnwrap(steady(to: 30, &t, extra: [other, twin]))
        XCTAssertEqual(r.backup, "A3")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 14:45. AMS may switch to A3.")

        let soon = try XCTUnwrap(steady(to: 48, &t))
        XCTAssertTrue(soon.soon)
        XCTAssertEqual(GlanceContent.runoutLine(soon), "PLA Matte in A2 is about to run out.")
    }

    func testNewJobFinishAndNotifyOnce() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(to: 30, &t))
        XCTAssertTrue(t.shouldNotify(serial: "x2d", runout: r))
        XCTAssertFalse(t.shouldNotify(serial: "x2d", runout: r))

        let saved = try JSONEncoder().encode(t)
        var restored = try JSONDecoder().decode(RunoutTracker.self, from: saved)
        XCTAssertNotNil(restored.observe(row(31, 10)), "survives a relaunch")
        XCTAssertFalse(restored.shouldNotify(serial: "x2d", runout: r))

        XCTAssertNil(t.observe(row(31, 10, job: "t2")), "a new job starts over")
        _ = t.observe(row(100, 0, state: "FINISH"))
        XCTAssertTrue(t.jobs.isEmpty)
    }
}
