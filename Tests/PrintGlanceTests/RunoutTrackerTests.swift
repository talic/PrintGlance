import XCTest
@testable import PrintGlance

final class RunoutTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 14:13:20 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// One spool at 30% that loses a point every 2% of progress, so it reads 0 at 60%.
    private func steady(
        _ range: ClosedRange<Int>,
        _ tracker: inout RunoutTracker,
        noise: [Int] = [0],
        extra: [AMSTray] = []
    ) -> Runout? {
        var last: Runout?
        for p in range {
            last = tracker.observe(
                row(p, 30 - p / 2 + noise[p % noise.count], extra: extra),
                now: now,
                calendar: utc,
                locale: Locale(identifier: "en_GB")
            )
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

    func testSteadyUse() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...30, &t))
        XCTAssertEqual(r.percent, 60)
        // 70% left takes 7000 s, so 30.5% more is 3052 s: 15:04:12, rounded to 15:05.
        XCTAssertEqual(r.at, "15:05")
        XCTAssertEqual(r.tray, "A2")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 15:05.")
    }

    func testReachesOnlyThreeTimesWhatItMeasured() {
        var a = RunoutTracker()
        XCTAssertNil(steady(1...16, &a), "readings cover 14%, 45% to go")
        var b = RunoutTracker()
        XCTAssertEqual(steady(1...17, &b)?.percent, 59, "readings cover 15%, 44% to go")
    }

    func testNoisyReadingsStayClose() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...30, &t, noise: [1, -1, 2, 0, -2, 1, 0, -1]))
        XCTAssertTrue((58...62).contains(r.percent), "\(r.percent)")
    }

    /// The X2D on 2026-10-01: a spool that swung 3–5, then read 0–2 for the last 20% of the print
    /// and never ran out. Counting drops said "about to run out" at 80%.
    func testNearlyEmptyNoisySpoolGuessesNothing() {
        let readings = [
            (63, 5), (63, 4), (64, 4), (65, 4), (66, 4), (66, 5), (67, 5), (67, 4), (67, 3), (68, 3),
            (69, 3), (69, 4), (70, 4), (70, 5), (71, 5), (71, 4), (72, 4), (73, 4), (73, 3), (74, 3),
            (74, 5), (75, 5), (75, 3), (76, 3), (76, 4), (77, 4), (78, 4), (78, 3), (79, 3), (79, 2),
            (80, 2), (80, 0), (81, 0), (81, 1), (82, 2), (82, 1), (83, 1), (84, 2), (84, 1), (85, 1),
            (86, 1), (87, 1), (88, 1), (89, 1), (89, 2), (90, 2), (90, 1), (91, 0), (92, 1), (93, 2),
            (93, 1), (94, 1), (95, 1), (95, 0), (96, 0), (97, 0), (98, 1), (99, 1),
        ]
        var t = RunoutTracker()
        for (p, remain) in readings {
            XCTAssertNil(t.observe(row(p, remain)), "\(p)% reading \(remain)")
        }
    }

    func testBelowFloorTheGuessHoldsThenGoes() throws {
        var t = RunoutTracker()
        XCTAssertEqual(steady(1...52, &t)?.percent, 60, "reads 4 at 52%: the fit stops there")
        XCTAssertEqual(t.observe(row(53, 0))?.percent, 60, "a stray 0 doesn't move it")
        XCTAssertTrue(try XCTUnwrap(t.observe(row(58, 3))).soon)
        XCTAssertNil(t.observe(row(61, 2)), "past the guess and still printing: it was wrong")
    }

    func testEnoughFilamentShowsNothing() {
        var t = RunoutTracker()
        var last: Runout?
        for p in 1...40 {
            last = t.observe(row(p, 80 - p / 2))
        }
        XCTAssertNil(last, "runs out at 160%")
    }

    func testSwingsKeepTheFitAndSwapsStartOver() {
        var t = RunoutTracker()
        XCTAssertNotNil(steady(1...30, &t))
        XCTAssertNotNil(t.observe(row(31, 17)), "two points up is the estimate swinging")
        XCTAssertNil(t.observe(row(32, 100)), "a fresh spool")
        XCTAssertNil(t.observe(row(33, 99, name: "PETG")), "another filament")
    }

    func testStartSequenceAndPausesDontCount() throws {
        var t = RunoutTracker()
        XCTAssertNil(t.observe(row(0, 34, state: "PREPARE", layer: 0)))
        for remain in [33, 32, 31, 30] {
            XCTAssertNil(t.observe(row(0, remain, layer: 0)))
        }
        var clean = RunoutTracker()
        _ = clean.observe(row(0, 30))
        XCTAssertEqual(steady(1...30, &t), steady(1...30, &clean), "purging at 0% leaves only where it ended")

        let paused = try XCTUnwrap(t.observe(row(30, 13, state: "PAUSE")))
        XCTAssertNil(paused.at)
        XCTAssertEqual(GlanceContent.runoutLine(paused), "PLA Matte in A2 runs out at about \(paused.percent)%.")
        XCTAssertEqual(t.observe(row(30, 15))?.percent, 60, "a paused reading adds nothing")
    }

    func testBackupSlot() throws {
        var t = RunoutTracker()
        let twin = AMSTray(id: "2", name: "PLA Matte", remain: nil, color: "F5C6A0FF", label: "A3", unit: "A")
        let other = AMSTray(id: "3", name: "PLA Matte", remain: nil, color: "000000FF", label: "A4", unit: "A")
        let r = try XCTUnwrap(steady(1...30, &t, extra: [other, twin]))
        XCTAssertEqual(r.backup, "A3")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 15:05. AMS may switch to A3.")
    }

    func testNewJobFinishAndNotifyOnce() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...30, &t))
        XCTAssertTrue(t.shouldNotify(serial: "x2d", runout: r))
        XCTAssertFalse(t.shouldNotify(serial: "x2d", runout: r))

        let saved = try JSONEncoder().encode(t)
        var restored = try JSONDecoder().decode(RunoutTracker.self, from: saved)
        XCTAssertNotNil(restored.observe(row(31, 15)), "survives a relaunch")
        XCTAssertFalse(restored.shouldNotify(serial: "x2d", runout: r))

        XCTAssertNil(t.observe(row(31, 15, job: "t2")), "a new job starts over")
        _ = t.observe(row(100, 0, state: "FINISH"))
        XCTAssertTrue(t.jobs.isEmpty)
    }
}
