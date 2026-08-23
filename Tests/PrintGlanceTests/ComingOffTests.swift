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
        XCTAssertEqual(action?.title, "Print finishing soon")
        XCTAssertEqual(action?.body, "Print in Parts on X2D. About 10 minutes left.")
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
        XCTAssertEqual(c.phase["x2d|t1"], .done)
        XCTAssertEqual(c.phase["x2d|t2"], .scheduled)
        XCTAssertEqual(next?.interval, 1800)
        XCTAssertTrue(next?.cancelIds.contains("pg.comingoff.x2d.t1") == true)
        XCTAssertTrue(next?.cancelIds.contains("pg.comingoff.x2d.t2") == true)
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
        XCTAssertTrue(QuietHours.contains(date(hour: 23, calendar: cal), calendar: cal))
        XCTAssertTrue(QuietHours.contains(date(hour: 2, calendar: cal), calendar: cal))
        XCTAssertFalse(QuietHours.contains(date(hour: 8, calendar: cal), calendar: cal))
        let fromNight = QuietHours.nextMorning(from: date(hour: 23, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: fromNight), 7)
        XCTAssertEqual(cal.component(.day, from: fromNight), 24)
        let fromDawn = QuietHours.nextMorning(from: date(hour: 2, calendar: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: fromDawn), 7)
        XCTAssertEqual(cal.component(.day, from: fromDawn), 23)
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
        var c = ComingOff()
        _ = c.consider(
            printer: printer("RUNNING", remainingS: 3600, jobId: "t1"),
            prefs: .default
        )
        c.save(d)
        let loaded = ComingOff.load(d)
        XCTAssertEqual(loaded.phase["x2d|t1"], .scheduled)
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
