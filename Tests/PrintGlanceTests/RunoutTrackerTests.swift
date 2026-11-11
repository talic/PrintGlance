import XCTest
@testable import PrintGlance

final class RunoutTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 14:13:20 UTC
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func observe(_ t: inout RunoutTracker, _ row: Printer, at date: Date? = nil) -> Runout? {
        t.observe(row, now: date ?? now, calendar: utc, locale: Locale(identifier: "en_GB"))
    }

    /// One spool at 30% that loses a point every 2% of an 8-hour print, so it reads 0 at 60%.
    /// That is 62 g an hour.
    private func steady(
        _ range: ClosedRange<Int>,
        _ tracker: inout RunoutTracker,
        noise: [Int] = [0],
        extra: [AMSTray] = []
    ) -> Runout? {
        var last: Runout?
        for p in range {
            last = observe(&tracker, row(p, 30 - p / 2 + noise[p % noise.count], extra: extra))
        }
        return last
    }

    /// The printer says each percent takes `pace` seconds.
    private func row(
        _ percent: Int,
        _ remain: Int?,
        state: String = "RUNNING",
        layer: Int = 5,
        job: String = "t1",
        name: String = "PLA Matte",
        pace: Int? = 288,
        grams: Int? = nil,
        extra: [AMSTray] = []
    ) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: state, percent: percent, jobId: job)
        p.layer = layer
        p.remainingS = pace.map { (100 - percent) * $0 }
        var tray = AMSTray(id: "1", name: name, remain: remain, color: "F5C6A0FF", label: "A2", unit: "A")
        tray.weight = grams
        p.trays = [tray] + extra
        return p
    }

    func testSteadyUse() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...30, &t))
        XCTAssertEqual(r.percent, 60)
        // 30.5% more at 288 s a percent is 8784 s: 16:39:44, rounded to 16:40.
        XCTAssertEqual(r.at, "16:40")
        XCTAssertEqual(r.tray, "A2")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 16:40.")
    }

    func testReachesOnlyTwiceWhatItMeasured() {
        var a = RunoutTracker()
        XCTAssertNil(steady(1...21, &a), "readings cover 19%, 40% to go")
        var b = RunoutTracker()
        XCTAssertEqual(steady(1...22, &b)?.percent, 60, "readings cover 20%, 39% to go")
    }

    func testNoisyReadingsStayClose() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...40, &t, noise: [1, -1, 2, 0, -2, 1, 0, -1]))
        XCTAssertTrue((58...62).contains(r.percent), "\(r.percent)")
    }

    /// The fall has to be twice the swing of the readings around the line.
    func testWaitsUntilTheFallBeatsTheSwings() {
        var t = RunoutTracker()
        let swinging = [3, -3, 2, -2, 3, -3, 1, -1]
        XCTAssertNil(steady(1...24, &t, noise: swinging), "fell 11, swings 6")
        XCTAssertNotNil(steady(25...40, &t, noise: swinging), "fell 19")
    }

    /// 2026-11-10: a spool near 50% read 58, then 47 within ten minutes, and the fit of the day
    /// said it would run out. That fall is over 600 g an hour.
    func testAFallNoNozzleCanMeltIsTheGaugeSwinging() {
        var t = RunoutTracker()
        var fast = RunoutTracker()
        for p in 20...40 {
            // 1.5 points a percent: 54 g an hour over 16 hours, 860 g an hour over one.
            let remain = 58 - (p - 20) * 3 / 2
            XCTAssertNil(observe(&fast, row(p, remain, pace: 36)), "\(p)%")
            _ = observe(&t, row(p, remain, pace: 576))
        }
        XCTAssertNotNil(observe(&t, row(41, 27, pace: 576)), "the same readings over 16 hours are real")
    }

    func testASmallSpoolEmptiesFaster() {
        var kilo = RunoutTracker()
        var quarter = RunoutTracker()
        for p in 1...16 {
            // Two points a percent: 62 g an hour off 250 g, 250 g an hour off a kilo.
            XCTAssertNil(observe(&kilo, row(p, 60 - p * 2)))
            _ = observe(&quarter, row(p, 60 - p * 2, grams: 250))
        }
        XCTAssertEqual(observe(&quarter, row(17, 26, grams: 250))?.percent, 30)
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
        XCTAssertEqual(observe(&t, row(53, 0))?.percent, 60, "a stray 0 doesn't move it")
        XCTAssertTrue(try XCTUnwrap(observe(&t, row(60, 3))).soon)
        XCTAssertNil(observe(&t, row(61, 2)), "past the guess and still printing: it was wrong")
    }

    func testEnoughFilamentShowsNothing() {
        var t = RunoutTracker()
        var last: Runout?
        for p in 1...40 {
            last = observe(&t, row(p, 80 - p / 2))
        }
        XCTAssertNil(last, "runs out at 160%")
    }

    func testSwingsKeepTheFitAndSwapsStartOver() {
        var t = RunoutTracker()
        XCTAssertNotNil(steady(1...30, &t))
        XCTAssertNotNil(observe(&t, row(31, 17)), "two points up is the gauge swinging")
        XCTAssertNil(observe(&t, row(32, 100)), "a fresh spool")
        XCTAssertNil(observe(&t, row(33, 99, name: "PETG")), "another filament")
    }

    func testStartSequenceAndPausesDontCount() throws {
        var t = RunoutTracker()
        XCTAssertNil(observe(&t, row(0, 34, state: "PREPARE", layer: 0)))
        for remain in [33, 32, 31, 30] {
            XCTAssertNil(observe(&t, row(0, remain, layer: 0)))
        }
        var clean = RunoutTracker()
        _ = observe(&clean, row(0, 30))
        XCTAssertEqual(steady(1...30, &t), steady(1...30, &clean), "purging at 0% leaves only where it ended")

        let paused = try XCTUnwrap(observe(&t, row(30, 13, state: "PAUSE")))
        XCTAssertNil(paused.at)
        XCTAssertEqual(GlanceContent.runoutLine(paused), "PLA Matte in A2 runs out at about \(paused.percent)%.")
        XCTAssertEqual(observe(&t, row(30, 15))?.percent, 60, "a paused reading adds nothing")
    }

    func testBackupSlot() throws {
        var t = RunoutTracker()
        let twin = AMSTray(id: "2", name: "PLA Matte", remain: nil, color: "F5C6A0FF", label: "A3", unit: "A")
        let other = AMSTray(id: "3", name: "PLA Matte", remain: nil, color: "000000FF", label: "A4", unit: "A")
        let r = try XCTUnwrap(steady(1...30, &t, extra: [other, twin]))
        XCTAssertEqual(r.backup, "A3")
        XCTAssertEqual(GlanceContent.runoutLine(r), "PLA Matte in A2 runs out around 16:40. AMS may switch to A3.")
    }

    func testNewJobFinishAndNotifyOnce() throws {
        var t = RunoutTracker()
        let r = try XCTUnwrap(steady(1...30, &t))
        XCTAssertTrue(t.shouldNotify(serial: "x2d", runout: r))
        XCTAssertFalse(t.shouldNotify(serial: "x2d", runout: r))

        let saved = try JSONEncoder().encode(t)
        var restored = try JSONDecoder().decode(RunoutTracker.self, from: saved)
        XCTAssertNotNil(observe(&restored, row(31, 15)), "survives a relaunch")
        XCTAssertFalse(restored.shouldNotify(serial: "x2d", runout: r))

        XCTAssertNil(observe(&t, row(31, 15, job: "t2")), "a new job starts over")
        _ = observe(&t, row(100, 0, state: "FINISH"))
        XCTAssertTrue(t.jobs.isEmpty)
    }

    /// 1.4 saved least-squares sums, not readings.
    func testAFitSavedByAnOlderBuildStartsOver() {
        let d = scratchDefaults()
        let old = #"{"jobs":{"x2d":{"id":"t1","noticed":["A2"],"spools":{"1":{"n":26,"sp":403,"sr":1360,"spp":7709,"spr":21778,"srr":72072,"firstAt":3,"lastAt":28,"name":"PLA Matte","color":"DE4343FF","pending":57,"pendingAt":29}}}}}"#
        d.set(Data(old.utf8), forKey: RunoutTracker.defaultsKey)
        XCTAssertEqual(RunoutTracker.load(d), RunoutTracker())
    }

    // MARK: - Pace

    /// The printer promises 100 s a percent; the clock shows 300.
    func testTheClockTimesTheRunoutOnceItHasSeenEnough() throws {
        var t = RunoutTracker()
        var last: Runout?
        for p in 1...30 {
            last = observe(&t, row(p, 30 - p / 2, pace: 100), at: now.addingTimeInterval(Double(p) * 300))
        }
        // 30.5% more at 300 s a percent is 9150 s after 16:43:20: 19:15:50.
        XCTAssertEqual(try XCTUnwrap(last).at, "19:15")
        XCTAssertEqual(t.jobs["x2d"]?.pace?.secondsPerPercent, 300)
    }

    func testPaceStartsOnAWholePercentAndNeedsThree() {
        var pace = Pace(percent: 10, now: now)
        pace.printing(10, now: now.addingTimeInterval(500))
        pace.printing(11, now: now.addingTimeInterval(600))
        pace.printing(13, now: now.addingTimeInterval(800))
        XCTAssertNil(pace.secondsPerPercent, "two percents since it first moved")
        pace.printing(14, now: now.addingTimeInterval(900))
        XCTAssertEqual(pace.secondsPerPercent, 100, "the wait at 10% is not counted")
    }

    func testPaceLeavesOutAPause() {
        var pace = Pace(percent: 10, now: now)
        pace.printing(11, now: now)
        pace.printing(13, now: now.addingTimeInterval(200))
        pace.paused(now: now.addingTimeInterval(250))
        pace.paused(now: now.addingTimeInterval(900))
        pace.printing(13, now: now.addingTimeInterval(3850))
        pace.printing(15, now: now.addingTimeInterval(4000))
        XCTAssertEqual(pace.secondsPerPercent, 100)
    }

    /// Reports replayed in a burst say nothing about speed, so the printer's number stands.
    func testABurstOfReportsIsNotAPace() {
        var pace = Pace(percent: 10, now: now)
        for p in 11...20 {
            pace.printing(p, now: now.addingTimeInterval(Double(p) / 100))
        }
        XCTAssertNil(pace.secondsPerPercent)
    }

    func testNoPaceNoGuess() {
        var t = RunoutTracker()
        for p in 1...30 {
            XCTAssertNil(observe(&t, row(p, 30 - p / 2, pace: nil)), "\(p)%")
        }
    }
}
