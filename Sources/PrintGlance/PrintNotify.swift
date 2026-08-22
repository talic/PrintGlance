import Foundation

enum PrintNotifyKind: String, Equatable {
    case finish
    case fail
    case pause
    case offline
}

struct PrintNotifyAlert: Equatable {
    var kind: PrintNotifyKind
    var title: String
    var body: String
}

struct PrintNotifyOutcome: Equatable {
    var requestPermission: Bool
    var alert: PrintNotifyAlert?
}

struct PrintNotifyPrefs: Equatable {
    var finish: Bool
    var fail: Bool
    var pause: Bool
    var offline: Bool

    static let `default` = PrintNotifyPrefs(finish: true, fail: true, pause: false, offline: true)

    static func load(_ d: UserDefaults) -> PrintNotifyPrefs {
        func flag(_ key: String, fallback: Bool) -> Bool {
            guard d.object(forKey: key) != nil else { return fallback }
            return d.bool(forKey: key)
        }
        return PrintNotifyPrefs(
            finish: flag("pg.notify.finish", fallback: true),
            fail: flag("pg.notify.fail", fallback: true),
            pause: flag("pg.notify.pause", fallback: false),
            offline: flag("pg.notify.offline", fallback: true)
        )
    }

    func save(_ d: UserDefaults) {
        d.set(finish, forKey: "pg.notify.finish")
        d.set(fail, forKey: "pg.notify.fail")
        d.set(pause, forKey: "pg.notify.pause")
        d.set(offline, forKey: "pg.notify.offline")
    }
}

struct PrintNotifyStamp: Equatable {
    var serial: String
    var state: String
    var jobId: String

    static func load(_ d: UserDefaults) -> PrintNotifyStamp? {
        guard let serial = d.string(forKey: "pg.notify.stamp.serial"), !serial.isEmpty,
              let state = d.string(forKey: "pg.notify.stamp.state"), !state.isEmpty
        else { return nil }
        return PrintNotifyStamp(
            serial: serial,
            state: state,
            jobId: d.string(forKey: "pg.notify.stamp.jobId") ?? ""
        )
    }

    func save(_ d: UserDefaults) {
        d.set(serial, forKey: "pg.notify.stamp.serial")
        d.set(state, forKey: "pg.notify.stamp.state")
        d.set(jobId, forKey: "pg.notify.stamp.jobId")
    }

    static func clear(_ d: UserDefaults) {
        d.removeObject(forKey: "pg.notify.stamp.serial")
        d.removeObject(forKey: "pg.notify.stamp.state")
        d.removeObject(forKey: "pg.notify.stamp.jobId")
    }
}

/// Decides print alerts from glance snapshot edges. Permission is requested on the first
/// RUNNING or PREPARE snapshot, not on FINISH, so the grant prompt cannot drop that alert.
struct PrintNotify {
    var serial: String
    var prefs: PrintNotifyPrefs
    var stamp: PrintNotifyStamp?
    var hadTimedJob = false
    var askedPermission = false
    var lastState: String?

    mutating func observe(_ content: GlanceContent) -> PrintNotifyOutcome {
        let row = content.row
        let next = Self.stateName(content)

        var requestPermission = false
        if next == "RUNNING" || next == "PREPARE" {
            requestPermission = !askedPermission
            askedPermission = true
            stamp = nil
        }

        let prev = lastState
        var alert: PrintNotifyAlert?
        if next == "FINISH", Self.isPrepareOrRunning(prev), prefs.finish {
            alert = Self.alert(.finish, row)
        } else if next == "FAILED", Self.isPrepareOrRunning(prev), prefs.fail {
            alert = Self.alert(.fail, row)
        } else if next == "PAUSE", Self.isPrepareOrRunning(prev), prefs.pause {
            alert = Self.alert(.pause, row)
        } else if next == "OFFLINE", prefs.offline, Self.isOfflineEdge(prev: prev, hadTimedJob: hadTimedJob) {
            alert = Self.alert(.offline, row)
        }

        if alert != nil {
            let candidate = PrintNotifyStamp(serial: serial, state: next, jobId: row?.jobId ?? "")
            if stamp == candidate {
                alert = nil
            } else {
                stamp = candidate
            }
        }

        lastState = next
        switch next {
        case "RUNNING", "PREPARE", "PAUSE":
            hadTimedJob = true
        case "FEEDDOWN", "OFFLINE":
            break
        default:
            hadTimedJob = false
        }

        return PrintNotifyOutcome(requestPermission: requestPermission, alert: alert)
    }

    func persistStamp(_ d: UserDefaults) {
        if let stamp {
            stamp.save(d)
        } else {
            PrintNotifyStamp.clear(d)
        }
    }

    private static func stateName(_ content: GlanceContent) -> String {
        switch content.result {
        case .doc:
            let state = (content.row?.state ?? "").uppercased()
            return state.isEmpty ? "OTHER" : state
        case .feedDown:
            return "FEEDDOWN"
        default:
            return "OTHER"
        }
    }

    private static func isPrepareOrRunning(_ prev: String?) -> Bool {
        prev == "RUNNING" || prev == "PREPARE"
    }

    private static func isOfflineEdge(prev: String?, hadTimedJob: Bool) -> Bool {
        switch prev {
        case "RUNNING", "PREPARE", "PAUSE":
            return true
        case "FEEDDOWN":
            return hadTimedJob
        default:
            return false
        }
    }

    private static func alert(_ kind: PrintNotifyKind, _ row: Printer?) -> PrintNotifyAlert? {
        guard let row else { return nil }
        let name = row.name.isEmpty ? "Printer" : row.name
        let body: String
        if let job = row.job, !job.isEmpty {
            body = "\(job) on \(name)"
        } else {
            body = name
        }
        let title: String
        switch kind {
        case .finish: title = "Print finished"
        case .fail: title = "Print failed"
        case .pause: title = "Print paused"
        case .offline: title = "Printer went offline"
        }
        return PrintNotifyAlert(kind: kind, title: title, body: body)
    }
}
