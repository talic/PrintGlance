import Foundation
import XCTest
@testable import PrintGlance

final class PrintNotifyTests: XCTestCase {
    func testNotifyIdentityAndOfflineInvariants() {
        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)

        _ = n.observe(GlanceContent(result: .connecting))
        let idle = n.observe(row("IDLE", jobId: nil, job: nil))
        XCTAssertFalse(idle.requestPermission, "permission not requested at idle launch")
        XCTAssertNil(idle.alert)

        var relaunch = PrintNotify(
            serial: "x2d",
            prefs: .default,
            stamp: PrintNotifyStamp(serial: "x2d", state: "FINISH", jobId: "task-1")
        )
        _ = relaunch.observe(GlanceContent(result: .connecting))
        XCTAssertNil(relaunch.observe(row("FINISH", jobId: "task-1")).alert, "no notify on relaunch already FINISH")
        XCTAssertFalse(relaunch.observe(row("FINISH", jobId: "task-1")).requestPermission)

        var fresh = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        _ = fresh.observe(GlanceContent(result: .connecting))
        XCTAssertNil(fresh.observe(row("FINISH", jobId: "task-1")).alert)

        let run = n.observe(row("RUNNING", jobId: "task-1"))
        XCTAssertTrue(run.requestPermission)
        XCTAssertNil(run.alert)
        XCTAssertNil(n.stamp, "stamp clears on RUNNING")
        XCTAssertFalse(n.observe(row("RUNNING", jobId: "task-1")).requestPermission)

        let done = n.observe(row("FINISH", jobId: "task-1"))
        XCTAssertEqual(done.alert?.kind, .finish)
        XCTAssertEqual(done.alert?.title, "Print finished")
        XCTAssertEqual(done.alert?.body, "Print in Parts on X2D")
        XCTAssertFalse(done.requestPermission)
        XCTAssertEqual(n.stamp, PrintNotifyStamp(serial: "x2d", state: "FINISH", jobId: "task-1"))
        XCTAssertNil(n.observe(row("FINISH", jobId: "task-1")).alert)

        _ = n.observe(row("RUNNING", jobId: "task-2"))
        XCTAssertNil(n.stamp, "remain stamp clears on RUNNING")
        let second = n.observe(row("FINISH", jobId: "task-2", job: "Print in Parts"))
        XCTAssertEqual(second.alert?.kind, .finish, "second job with same display name still notifies if task_id changed")
        XCTAssertEqual(n.stamp?.jobId, "task-2")

        _ = n.observe(row("RUNNING", jobId: "task-3"))
        let down = n.observe(GlanceContent(result: .feedDown))
        XCTAssertNil(down.alert, "do not notify on feedDown")
        let offline = n.observe(row("OFFLINE", jobId: "task-3"))
        XCTAssertEqual(offline.alert?.kind, .offline)
        XCTAssertEqual(offline.alert?.title, "Lost connection to X2D")
        XCTAssertEqual(offline.alert?.body, "Print in Parts was at 16%. PrintGlance keeps trying.")
        XCTAssertNil(n.observe(row("OFFLINE", jobId: "task-3")).alert, "feedDown then OFFLINE is one alert")

        var pauseOff = n
        pauseOff.prefs.pause = false
        _ = pauseOff.observe(row("RUNNING", jobId: "task-4"))
        XCTAssertNil(pauseOff.observe(row("PAUSE", jobId: "task-4")).alert, "pause off")
        _ = n.observe(row("RUNNING", jobId: "task-4"))
        XCTAssertEqual(n.observe(row("PAUSE", jobId: "task-4")).alert?.kind, .pause, "pause default on")

        _ = n.observe(row("RUNNING", jobId: "task-5"))
        let failed = n.observe(row("FAILED", jobId: "task-5"))
        XCTAssertEqual(failed.alert?.kind, .fail)
        XCTAssertEqual(failed.alert?.title, "Print failed")

        let fromPrint = [
            "gcode_state": "RUNNING",
            "task_id": "t-mqtt",
            "subtask_id": "s-mqtt",
            "subtask_name": "Print in Parts",
        ] as [String: Any]
        XCTAssertEqual(
            BambuPrint.row(id: "x2d", name: "X2D", printObj: fromPrint, online: true).jobId,
            "t-mqtt"
        )
        XCTAssertEqual(
            BambuPrint.row(
                id: "x2d",
                name: "X2D",
                printObj: ["gcode_state": "RUNNING", "subtask_id": 99, "subtask_name": "Print in Parts"],
                online: true
            ).jobId,
            "99"
        )
        XCTAssertNil(
            BambuPrint.row(
                id: "x2d",
                name: "X2D",
                printObj: ["gcode_state": "FINISH", "subtask_name": "Print in Parts"],
                online: true
            ).jobId
        )
    }

    func testFleetFinishNotifiesUnfocusedPrinter() {
        var n = PrintNotify(serial: "aaa", prefs: .default, stamp: nil)
        let aRun = Printer(id: "aaa", name: "A", state: "RUNNING", percent: 16, job: "Job A", jobId: "t-a")
        var b = Printer(id: "bbb", name: "B", state: "RUNNING", percent: 40, job: "Job B", jobId: "t-b")
        XCTAssertNil(n.observe(fleet(focus: "aaa", [aRun, b])).alert)
        b.state = "FINISH"
        let done = n.observe(fleet(focus: "aaa", [aRun, b]))
        XCTAssertEqual(done.alerts.map(\.kind), [.finish])
        XCTAssertEqual(done.alert?.serial, "bbb")
        XCTAssertEqual(done.alert?.body, "Job B on B")
        XCTAssertNil(
            n.observe(fleet(focus: "bbb", [aRun, b])).alert,
            "focus switch is not a second finish"
        )
    }

    func testFocusOntoAlreadyFinishedIsNotFinish() {
        var n = PrintNotify(serial: "aaa", prefs: .default, stamp: nil)
        let aRun = Printer(id: "aaa", name: "A", state: "RUNNING", percent: 16, job: "Job A", jobId: "t-a")
        let bDone = Printer(id: "bbb", name: "B", state: "FINISH", percent: 100, job: "Job B", jobId: "t-b")
        XCTAssertNil(n.observe(fleet(focus: "aaa", [aRun])).alert)
        XCTAssertNil(n.observe(fleet(focus: "bbb", [aRun, bDone])).alert)
    }

    func testConnectingDoesNotClearOffline() {
        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        XCTAssertNil(n.observe(row("RUNNING", jobId: "t1")).alert)
        XCTAssertNil(n.observe(GlanceContent(result: .connecting)).alert)
        XCTAssertNil(n.observe(GlanceContent(result: .feedDown)).alert)
        XCTAssertEqual(n.observe(row("OFFLINE", jobId: "t1")).alert?.kind, .offline)
    }

    func testPauseDefaultsOnAndMigratesOnce() throws {
        XCTAssertTrue(PrintNotifyPrefs.default.pause)
        let name = "PrintGlance.pause.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }

        XCTAssertTrue(PrintNotifyPrefs.load(d).pause, "fresh install")

        d.removePersistentDomain(forName: name)
        PrintNotifyPrefs(finish: true, fail: true, pause: false, offline: true, comingOff: true, quietHours: false).save(d)
        XCTAssertTrue(PrintNotifyPrefs.load(d).pause, "existing install gets pause on once")

        var prefs = PrintNotifyPrefs.load(d)
        prefs.pause = false
        prefs.save(d)
        XCTAssertFalse(PrintNotifyPrefs.load(d).pause, "turning it off after the migration sticks")
    }

    func testLostConnectionBodyWithoutJobOrPercent() {
        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        _ = n.observe(row("RUNNING", jobId: "t1", job: nil))
        XCTAssertEqual(n.observe(row("OFFLINE", jobId: "t1", job: nil)).alert?.body, "X2D was at 16%. PrintGlance keeps trying.")

        var bare = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        let running = Printer(id: "x2d", name: "X2D", state: "RUNNING", percent: nil, job: "Benchy", jobId: "t1")
        var offline = running
        offline.state = "OFFLINE"
        _ = bare.observe(GlanceContent(result: .doc(PrintDoc(v: 1, updatedAt: nil, focusId: "x2d", printers: [running]))))
        let alert = bare.observe(GlanceContent(result: .doc(PrintDoc(v: 1, updatedAt: nil, focusId: "x2d", printers: [offline])))).alert
        XCTAssertEqual(alert?.body, "PrintGlance keeps trying.")
    }

    func testLostConnectionSkippedWhenThisMacCausedIt() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(PrintNotify.offlineAlertAllowed(macOnline: true, networkChangedAt: nil, now: now))
        XCTAssertFalse(PrintNotify.offlineAlertAllowed(macOnline: false, networkChangedAt: nil, now: now), "no network on this Mac")
        XCTAssertFalse(
            PrintNotify.offlineAlertAllowed(macOnline: true, networkChangedAt: now - 119, now: now),
            "network changed under 2 minutes ago"
        )
        XCTAssertTrue(PrintNotify.offlineAlertAllowed(macOnline: true, networkChangedAt: now - 120, now: now))
        XCTAssertFalse(PrintNotify.offlineAlertAllowed(macOnline: false, networkChangedAt: now - 3600, now: now))
    }

    func testLowFilamentPrefDefaultsOnAndSaves() throws {
        XCTAssertTrue(PrintNotifyPrefs.default.lowFilament)
        let name = "PrintGlance.lowFilament.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }

        XCTAssertTrue(PrintNotifyPrefs.load(d).lowFilament, "fresh install")
        var prefs = PrintNotifyPrefs.load(d)
        prefs.lowFilament = false
        prefs.save(d)
        XCTAssertEqual(d.object(forKey: "pg.notify.lowFilament") as? Bool, false)
        XCTAssertFalse(PrintNotifyPrefs.load(d).lowFilament)
        XCTAssertTrue(PrintNotifyPrefs.load(d).finish, "other prefs untouched")
    }

    func testPauseAndFailBodiesEndWithErrorCode() {
        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        _ = n.observe(row("RUNNING", jobId: "t1"))
        var paused = Printer(id: "x2d", name: "X2D", state: "PAUSE", percent: 16, job: "Print in Parts", jobId: "t1")
        paused.printError = "0700-8002"
        let out = n.observe(GlanceContent(result: .doc(PrintDoc(v: 1, updatedAt: nil, focusId: "x2d", printers: [paused]))))
        XCTAssertEqual(out.alert?.kind, .pause)
        XCTAssertEqual(out.alert?.body, "Print in Parts on X2D · Error 0700-8002")
    }

    private func row(_ state: String, jobId: String?, job: String? = "Print in Parts") -> GlanceContent {
        let printer = Printer(id: "x2d", name: "X2D", state: state, percent: 16, job: job, jobId: jobId)
        return GlanceContent(result: .doc(PrintDoc(v: 1, updatedAt: nil, focusId: "x2d", printers: [printer])))
    }

    private func fleet(focus: String, _ printers: [Printer]) -> GlanceContent {
        GlanceContent(result: .doc(PrintDoc(v: 1, updatedAt: nil, focusId: focus, printers: printers)))
    }
}
