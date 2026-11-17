import Foundation
import XCTest
@testable import PrintGlance

final class ComingOffTests: XCTestCase {
    func testScheduleAtRemainingMinus10m() {
        var c = ComingOff()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let action = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default,
            now: now
        )
        XCTAssertEqual(action?.interval, 3000)
        XCTAssertEqual(action?.immediate, false)
        XCTAssertEqual(action?.title, "X2D finishing soon")
        XCTAssertEqual(action?.subtitle, "Print in Parts")
        XCTAssertEqual(action?.body, "About 10 minutes left.")
        XCTAssertEqual(c.phase["x2d|t1"], .scheduled)

        XCTAssertNil(
            c.consider(
                printer: printer("RUNNING", remainingS: 3580, jobId: "t1"),
                prefs: .default,
                now: now.addingTimeInterval(20)
            ),
            "second snapshot does not re-add"
        )
    }

    func testEachLeadTime() {
        for lead in PrintNotifyPrefs.comingOffLeads {
            var prefs = PrintNotifyPrefs.default
            prefs.comingOffLead = lead
            var c = ComingOff()
            let action = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: prefs)
            XCTAssertEqual(action?.interval, TimeInterval(3600 - lead * 60), "\(lead)")
            XCTAssertEqual(action?.body, "About \(lead) minutes left.")
        }
        XCTAssertEqual(PrintNotifyPrefs.default.comingOffLead, 10)
    }

    func testChangingLeadTimeReschedulesOnce() {
        var c = ComingOff()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var prefs = PrintNotifyPrefs.default
        _ = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: prefs, now: now)
        prefs.comingOffLead = 30
        let moved = c.consider(printer: printer("RUNNING", remainingS: 3590, jobId: "t1"), prefs: prefs, now: now + 10)
        XCTAssertEqual(moved?.interval, 1790)
        XCTAssertEqual(moved?.identifier, "pg.comingoff.x2d.t1", "same id replaces the pending notice")
        XCTAssertEqual(moved?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertEqual(moved?.body, "About 30 minutes left.")
        XCTAssertNil(
            c.consider(printer: printer("RUNNING", remainingS: 3570, jobId: "t1"), prefs: prefs, now: now + 30),
            "rescheduled once"
        )

        prefs.comingOffLead = 5
        XCTAssertEqual(
            c.consider(printer: printer("RUNNING", remainingS: 3560, jobId: "t1"), prefs: prefs, now: now + 40)?.interval,
            3260
        )

        for a in PrintNotifyPrefs.comingOffLeads {
            for b in PrintNotifyPrefs.comingOffLeads where a != b {
                XCTAssertGreaterThan(abs(a - b) * 60, ComingOff.jumpS, "\(a) to \(b) moves the notice past a jump")
            }
        }
    }

    func testInsideLeadTimeSaysWhatIsLeft() {
        var prefs = PrintNotifyPrefs.default
        prefs.comingOffLead = 30
        var c = ComingOff()
        let late = c.consider(printer: printer("RUNNING", remainingS: 170, jobId: "t1"), prefs: prefs)
        XCTAssertEqual(late?.immediate, true)
        XCTAssertEqual(late?.body, "About 3 minutes left.")

        var d = ComingOff()
        XCTAssertEqual(
            d.consider(printer: printer("RUNNING", remainingS: 30, jobId: "t2"), prefs: prefs)?.body,
            "About 1 minute left."
        )

        var e = ComingOff()
        _ = e.consider(printer: printer("RUNNING", remainingS: 1500, jobId: "t3"), prefs: .default)
        let raised = e.consider(printer: printer("RUNNING", remainingS: 1490, jobId: "t3"), prefs: prefs)
        XCTAssertEqual(raised?.immediate, true, "a longer lead time than what's left fires now")
        XCTAssertEqual(raised?.body, "About 25 minutes left.")
        XCTAssertNil(e.consider(printer: printer("RUNNING", remainingS: 1480, jobId: "t3"), prefs: prefs))
    }

    func testLeadTimePrefLoadsAndSaves() throws {
        let name = "PrintGlance.lead.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }

        XCTAssertEqual(PrintNotifyPrefs.load(d).comingOffLead, 10, "fresh install")
        var prefs = PrintNotifyPrefs.load(d)
        prefs.comingOffLead = 15
        prefs.save(d)
        XCTAssertEqual(d.object(forKey: "pg.notify.comingOffLead") as? Int, 15)
        XCTAssertEqual(PrintNotifyPrefs.load(d).comingOffLead, 15)
        d.set(7, forKey: "pg.notify.comingOffLead")
        XCTAssertEqual(PrintNotifyPrefs.load(d).comingOffLead, 10, "not a choice in the menu")
    }

    func testRemainingJumpReschedules() {
        var c = ComingOff()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default,
            now: now
        )
        let again = c.consider(
            printer: printer("RUNNING", remainingS: 1800, jobId: "t1"),
            prefs: .default,
            now: now
        )
        XCTAssertEqual(again?.interval, 1200)
    }

    /// The printer counts down in whole minutes as the clock runs, so the delay to the notice
    /// shrinks but its time doesn't move. Reports twice a minute from 60 minutes left to Finished.
    func testASteadyPrintIsScheduledOnce() {
        var c = ComingOff()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var actions: [ComingOffAction] = []
        for minute in 0..<60 {
            for second in [0, 30] {
                let report = printer("RUNNING", remainingS: (60 - minute) * 60, jobId: "t1")
                let now = start.addingTimeInterval(TimeInterval(minute * 60 + second))
                if let action = c.consider(printer: report, prefs: .default, now: now) {
                    actions.append(action)
                }
            }
        }
        if let done = c.consider(printer: printer("FINISH", remainingS: 0, jobId: "t1"), prefs: .default, now: start + 3600) {
            actions.append(done)
        }
        XCTAssertEqual(actions.map(\.interval), [3000], "one schedule, and nothing again when it fires")
        XCTAssertEqual(actions.first?.body, "About 10 minutes left.")
        XCTAssertEqual(c.phase["x2d|t1"], .done)
    }

    /// Time left grows by 5 minutes halfway: the notice moves once. A 2-minute wobble doesn't move it.
    func testTimeLeftJumpingReschedulesOnce() {
        var c = ComingOff()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func report(minute: Int, minutesLeft: Int) -> ComingOffAction? {
            c.consider(
                printer: printer("RUNNING", remainingS: minutesLeft * 60, jobId: "t1"),
                prefs: .default,
                now: start.addingTimeInterval(TimeInterval(minute * 60))
            )
        }
        XCTAssertEqual(report(minute: 0, minutesLeft: 60)?.interval, 3000)
        for minute in 1...20 {
            XCTAssertNil(report(minute: minute, minutesLeft: 60 - minute), "minute \(minute)")
        }
        let moved = report(minute: 21, minutesLeft: 44)
        XCTAssertEqual(moved?.interval, 34 * 60, "39 minutes left plus 5")
        XCTAssertEqual(moved?.cancelIds, ["pg.comingoff.x2d.t1"], "replaces the pending notice")
        for minute in 22...30 {
            XCTAssertNil(report(minute: minute, minutesLeft: 65 - minute), "minute \(minute)")
        }
        XCTAssertNil(report(minute: 31, minutesLeft: 36), "2 minutes longer is not a jump")
        XCTAssertNil(report(minute: 32, minutesLeft: 33), "nor 2 minutes shorter")
    }

    /// Time left drops into the lead time well before the notice was due: it comes at once.
    func testTimeLeftDroppingIntoTheLeadTimeFiresNow() {
        var c = ComingOff()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: .default, now: start)
        let now = c.consider(printer: printer("RUNNING", remainingS: 420, jobId: "t1"), prefs: .default, now: start + 600)
        XCTAssertEqual(now?.immediate, true)
        XCTAssertEqual(now?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertEqual(now?.body, "About 7 minutes left.")
    }

    func testAlreadyUnder10mFiresOnce() {
        var c = ComingOff()
        let first = c.consider(
            printer: printer("RUNNING", remainingS: 540, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(first?.immediate, true)
        XCTAssertEqual(c.phase["x2d|t1"], .done)
        XCTAssertNil(
            c.consider(
                printer: printer("RUNNING", remainingS: 500, jobId: "t1"),
                prefs: .default
            )
        )
    }

    func testRelaunchAlreadyUnder10mDoesNotFire() {
        var c = ComingOff()
        c.phase["x2d|t1"] = .done
        XCTAssertNil(
            c.consider(
                printer: printer("RUNNING", remainingS: 400, jobId: "t1"),
                prefs: .default
            )
        )
    }

    func testPauseCancelsWithoutDoneThenResumeReschedules() {
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        let pause = c.consider(
            printer: printer("PAUSE", remainingS: 3500, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(pause?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertNil(pause?.interval)
        XCTAssertEqual(pause?.immediate, false)
        XCTAssertNil(c.phase["x2d|t1"])

        let resume = c.consider(
            printer: printer("RUNNING", remainingS: 3400, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(resume?.interval, 2800)
        XCTAssertEqual(c.phase["x2d|t1"], .scheduled)
    }

    func testOfflineCancelsWithoutDone() {
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        let off = c.consider(
            printer: printer("OFFLINE", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(off?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertNil(c.phase["x2d|t1"])
    }

    func testFinishCancelsAndDoneNoComingOffAfterFinish() {
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        let done = c.consider(
            printer: printer("FINISH", remainingS: 0, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(done?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertEqual(c.phase["x2d|t1"], .done)
        XCTAssertNil(
            c.consider(
                printer: printer("FINISH", remainingS: 0, jobId: "t1"),
                prefs: .default
            )
        )
    }

    /// 2026-11-10 16:27: the next job's ID arrived while the printer still said Finished (100%, no
    /// time left), a second before Starting. Marking that job done silenced its notice for the
    /// whole print.
    func testTheNextJobsIdWhileStillFinishedDoesNotSilenceIt() {
        var c = ComingOff()
        _ = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: .default)
        _ = c.consider(printer: printer("FINISH", remainingS: 0, jobId: "t1"), prefs: .default)
        XCTAssertNil(c.consider(printer: printer("FINISH", remainingS: 0, jobId: "t2"), prefs: .default))
        XCTAssertNil(c.phase["x2d|t2"])
        XCTAssertNil(c.consider(printer: printer("PREPARE", remainingS: 7260, jobId: "t2"), prefs: .default))
        let soon = c.consider(printer: printer("RUNNING", remainingS: 6960, jobId: "t2"), prefs: .default)
        XCTAssertEqual(soon?.interval, 6360)
        XCTAssertEqual(c.phase["x2d|t2"], .scheduled)
    }

    func testAJobNeverSeenPrintingIsLeftAlone() {
        for state in ["FINISH", "FAILED", "IDLE"] {
            var c = ComingOff()
            XCTAssertNil(c.consider(printer: printer(state, remainingS: 0, jobId: "t9"), prefs: .default), state)
            XCTAssertEqual(c.phase, [:], state)
        }
    }

    func testIdleAndFailedMarkDone() {
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        _ = c.consider(
            printer: printer("FAILED", remainingS: 1000, jobId: "t1"),
            prefs: .default
        )
        XCTAssertEqual(c.phase["x2d|t1"], .done)
        var d = ComingOff()
        _ = d.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t2"),
            prefs: .default
        )
        _ = d.consider(
            printer: printer("IDLE", remainingS: 0, jobId: "t2"),
            prefs: .default
        )
        XCTAssertEqual(d.phase["x2d|t2"], .done)
    }

    func testJobChangeCancelsOld() {
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        let next = c.consider(
            printer: printer("RUNNING", remainingS: 2400, jobId: "t2"),
            prefs: .default
        )
        XCTAssertNil(c.phase["x2d|t1"])
        XCTAssertEqual(c.phase["x2d|t2"], .scheduled)
        XCTAssertEqual(next?.interval, 1800)
        XCTAssertTrue(next?.cancelIds.contains("pg.comingoff.x2d.t1") == true)
        XCTAssertTrue(next?.cancelIds.contains("pg.comingoff.x2d.t2") == true)
    }

    func testOldJobsArePrunedNotKept() {
        var c = ComingOff()
        for job in ["t1", "t2", "t3"] {
            _ = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: job), prefs: .default)
            _ = c.consider(printer: printer("FINISH", remainingS: 0, jobId: job), prefs: .default)
        }
        XCTAssertEqual(c.phase.count, 1)
        XCTAssertEqual(c.phase["x2d|t3"], .done)

        var stale = ComingOff()
        stale.phase = ["x2d|old1": .done, "x2d|old2": .done, "x2d|t3": .done, "p1s|j1": .done]
        XCTAssertNil(
            stale.consider(printer: printer("FINISH", remainingS: 0, jobId: "t3"), prefs: .default),
            "stale done neighbours cancel nothing"
        )
        XCTAssertEqual(stale.phase, ["x2d|t3": .done, "p1s|j1": .done])
    }

    func testQuietHoursSkipsComingOff() {
        let cal = utc()
        var prefs = PrintNotifyPrefs.default
        prefs.quietHours = true
        var c = ComingOff()
        let night = date(hour: 23, calendar: cal)
        let action = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: prefs,
            now: night,
            calendar: cal
        )
        XCTAssertEqual(action?.immediate, false)
        XCTAssertNil(action?.interval)
        XCTAssertEqual(c.phase["x2d|t1"], .done)
    }

    func testQuietHoursContainsAndNextMorning() {
        let cal = utc()
        let quiet = QuietHours.default
        XCTAssertTrue(quiet.contains(date(hour: 23, calendar: cal), calendar: cal))
        XCTAssertTrue(quiet.contains(date(hour: 2, calendar: cal), calendar: cal))
        XCTAssertFalse(quiet.contains(date(hour: 8, calendar: cal), calendar: cal))
        let fromNight = quiet.nextMorning(from: date(hour: 23, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: fromNight), 7)
        XCTAssertEqual(cal.component(.day, from: fromNight), 24)
        let fromDawn = quiet.nextMorning(from: date(hour: 2, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: fromDawn), 7)
        XCTAssertEqual(cal.component(.day, from: fromDawn), 23)
    }

    func testEachQuietHoursWindowIsNineHours() {
        let cal = utc()
        for start in QuietHours.starts {
            let quiet = QuietHours(startHour: start)
            let inside = (0..<24).filter { quiet.contains(date(hour: $0, calendar: cal), calendar: cal) }
            XCTAssertEqual(inside.count, 9, "\(start)")
            XCTAssertTrue(inside.contains(start), "\(start)")
            XCTAssertFalse(inside.contains(quiet.endHour), "ends on the hour: \(start)")
            XCTAssertEqual(quiet.endHour, (start + 9) % 24)
        }
        let midnight = QuietHours(startHour: 0)
        XCTAssertFalse(midnight.contains(date(hour: 23, calendar: cal), calendar: cal))
        XCTAssertTrue(midnight.contains(date(hour: 8, calendar: cal), calendar: cal))
        let morning = midnight.nextMorning(from: date(hour: 3, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: morning), 9)
        XCTAssertEqual(cal.component(.day, from: morning), 23)
        let fromNine = QuietHours(startHour: 21).nextMorning(from: date(hour: 21, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: fromNine), 6)
        XCTAssertEqual(cal.component(.day, from: fromNine), 24)
    }

    /// The Finished notice's trigger: held to the chosen window's end, or shown now outside it.
    func testFinishedWaitsForTheChosenWindowsEnd() {
        let cal = utc()
        let late = QuietHours(startHour: 23)
        let held = late.finishShowsAt(date(hour: 23, calendar: cal), calendar: cal)
        XCTAssertEqual([held?.day, held?.hour, held?.minute], [24, 8, 0], "an 11 PM–8 AM window waits for 8 the next morning")
        let dawn = late.finishShowsAt(date(hour: 7, calendar: cal), calendar: cal)
        XCTAssertEqual([dawn?.day, dawn?.hour], [23, 8], "inside the window after midnight: that morning")
        XCTAssertNil(late.finishShowsAt(date(hour: 22, calendar: cal), calendar: cal), "before the window: now")
        XCTAssertNil(QuietHours.default.finishShowsAt(date(hour: 7, calendar: cal), calendar: cal), "the default window has ended at 7")
        let midnight = QuietHours(startHour: 0).finishShowsAt(date(hour: 0, calendar: cal), calendar: cal)
        XCTAssertEqual([midnight?.day, midnight?.hour], [23, 9])
    }

    func testQuietHoursSkipsComingOffInTheChosenWindow() {
        let cal = utc()
        var prefs = PrintNotifyPrefs.default
        prefs.quietWindow = QuietHours(startHour: 0)
        var c = ComingOff()
        let late = c.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: prefs, now: date(hour: 22, calendar: cal), calendar: cal)
        XCTAssertEqual(late?.interval, 3000, "22:50 is before midnight")
        var d = ComingOff()
        let night = d.consider(printer: printer("RUNNING", remainingS: 3600, jobId: "t1"), prefs: prefs, now: date(hour: 7, calendar: cal), calendar: cal)
        XCTAssertNil(night?.interval, "07:50 is inside midnight–9")
        XCTAssertEqual(d.phase["x2d|t1"], .done)
    }

    func testQuietHoursTitleFollowsHourCycle() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(GlanceContent.quietHoursTitle(.default, locale: us), "Quiet Hours (10 PM–7 AM)")
        XCTAssertEqual(GlanceContent.quietHoursTitle(.default, locale: Locale(identifier: "en_GB")), "Quiet Hours (22:00–07:00)")
        XCTAssertEqual(GlanceContent.quietHoursTitle(.default, locale: Locale(identifier: "de_DE")), "Quiet Hours (22:00–07:00)", "quoted Uhr is not an hour letter")
        XCTAssertEqual(GlanceContent.quietHoursTitle(nil, locale: us), "Quiet Hours (Off)")
        XCTAssertEqual(
            PrintNotifyPrefs.quietHoursChoices.map { GlanceContent.quietHoursChoice($0, locale: us) },
            ["Off", "9 PM–6 AM", "10 PM–7 AM", "11 PM–8 AM", "Midnight–9 AM"]
        )
        XCTAssertEqual(
            PrintNotifyPrefs.quietHoursChoices.map { GlanceContent.quietHoursChoice($0, locale: Locale(identifier: "en_GB")) },
            ["Off", "21:00–06:00", "22:00–07:00", "23:00–08:00", "00:00–09:00"]
        )
    }

    func testFinishingSoonMenuShowsItsValue() {
        XCTAssertEqual(GlanceContent.finishingSoonTitle(lead: 10), "Print Finishing Soon (10 Min Before)")
        XCTAssertEqual(GlanceContent.finishingSoonTitle(lead: nil), "Print Finishing Soon (Off)")
        XCTAssertEqual(
            PrintNotifyPrefs.finishingSoonChoices.map(GlanceContent.finishingSoonChoice(lead:)),
            ["Off", "5 Minutes Before", "10 Minutes Before", "15 Minutes Before", "30 Minutes Before"]
        )
    }

    /// One menu choice sets the on/off flag and the value together; off keeps the last value.
    func testOneChoiceSetsTheFlagAndTheValue() throws {
        var prefs = PrintNotifyPrefs.default
        XCTAssertEqual(prefs.finishingSoonLead, 10)
        XCTAssertNil(prefs.quietWindow)
        prefs.finishingSoonLead = nil
        XCTAssertFalse(prefs.comingOff)
        XCTAssertEqual(prefs.comingOffLead, 10)
        prefs.finishingSoonLead = 30
        XCTAssertTrue(prefs.comingOff)
        XCTAssertEqual(prefs.comingOffLead, 30)
        prefs.quietWindow = QuietHours(startHour: 23)
        XCTAssertTrue(prefs.quietHours)
        XCTAssertEqual(prefs.quietHoursStart, 23)
        prefs.quietWindow = nil
        XCTAssertFalse(prefs.quietHours)
        XCTAssertEqual(prefs.quietHoursStart, 23)

        let d = scratchDefaults()
        XCTAssertEqual(PrintNotifyPrefs.load(d).quietHoursStart, 22, "fresh install")
        prefs.quietWindow = QuietHours(startHour: 0)
        prefs.save(d)
        XCTAssertEqual(d.object(forKey: "pg.notify.quietHoursStart") as? Int, 0)
        XCTAssertEqual(d.object(forKey: "pg.notify.quietHours") as? Bool, true)
        XCTAssertEqual(PrintNotifyPrefs.load(d).quietWindow, QuietHours(startHour: 0), "midnight is a choice, not a missing key")
        d.set(5, forKey: "pg.notify.quietHoursStart")
        XCTAssertEqual(PrintNotifyPrefs.load(d).quietHoursStart, 22, "not a choice in the menu")
    }

    func testPrefOffDoesNotSchedule() {
        var prefs = PrintNotifyPrefs.default
        prefs.comingOff = false
        var c = ComingOff()
        XCTAssertNil(
            c.consider(
                printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
                prefs: prefs
            )
        )
    }

    func testPersistRoundTrip() {
        let name = "PrintGlance.comingoff.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default,
            now: start
        )
        c.save(d)
        var loaded = ComingOff.load(d)
        XCTAssertEqual(loaded, c)
        XCTAssertEqual(loaded.phase["x2d|t1"], .scheduled)
        XCTAssertEqual(d.dictionary(forKey: "pg.comingoff.fireAt") as? [String: Int], ["x2d|t1": 1_700_003_000])
        XCTAssertNil(
            loaded.consider(printer: printer("RUNNING", remainingS: 3000, jobId: "t1"), prefs: .default, now: start + 600),
            "relaunched 10 minutes on, the notice already pending stays"
        )
    }

    /// Before this, `pg.comingoff.remain` held the delay from when the notice was scheduled. That
    /// says nothing about when it fires, so it reschedules once and the old key goes.
    func testAnOldSavedDelayReschedulesOnce() throws {
        let d = scratchDefaults()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        d.set(["x2d|t1": "scheduled"], forKey: "pg.comingoff.phase")
        d.set(["x2d|t1": 3000], forKey: "pg.comingoff.remain")
        var c = ComingOff.load(d)
        XCTAssertEqual(c.phase["x2d|t1"], .scheduled)
        XCTAssertEqual(c.scheduledFireAt, [:])
        let again = c.consider(printer: printer("RUNNING", remainingS: 3000, jobId: "t1"), prefs: .default, now: start)
        XCTAssertEqual(again?.interval, 2400)
        XCTAssertEqual(again?.cancelIds, ["pg.comingoff.x2d.t1"])
        XCTAssertNil(c.consider(printer: printer("RUNNING", remainingS: 2940, jobId: "t1"), prefs: .default, now: start + 60))
        c.save(d)
        XCTAssertNil(d.object(forKey: "pg.comingoff.remain"))
        XCTAssertEqual(ComingOff.load(d), c)
    }

    private func printer(_ state: String, remainingS: Int, jobId: String) -> Printer {
        Printer(
            id: "x2d",
            name: "X2D",
            state: state,
            percent: 80,
            remainingS: remainingS,
            job: "Print in Parts",
            jobId: jobId
        )
    }

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func date(hour: Int, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 23
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)!
    }
}
