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
    var serial: String
}

struct PrintNotifyOutcome: Equatable {
    var requestPermission: Bool
    var alerts: [PrintNotifyAlert]

    var alert: PrintNotifyAlert? { alerts.first }

    init(requestPermission: Bool, alert: PrintNotifyAlert?) {
        self.requestPermission = requestPermission
        self.alerts = alert.map { [$0] } ?? []
    }

    init(requestPermission: Bool, alerts: [PrintNotifyAlert]) {
        self.requestPermission = requestPermission
        self.alerts = alerts
    }
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

    static let listKey = "pg.notify.stamps"

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

    static func loadAll(_ d: UserDefaults) -> [String: PrintNotifyStamp] {
        if let raw = d.array(forKey: listKey) {
            var out: [String: PrintNotifyStamp] = [:]
            for item in raw {
                guard let dict = item as? [String: String],
                      let serial = dict["serial"], !serial.isEmpty,
                      let state = dict["state"], !state.isEmpty
                else { continue }
                out[serial] = PrintNotifyStamp(
                    serial: serial,
                    state: state,
                    jobId: dict["jobId"] ?? ""
                )
            }
            if !out.isEmpty { return out }
        }
        if let one = load(d) {
            return [one.serial: one]
        }
        return [:]
    }

    func save(_ d: UserDefaults) {
        d.set(serial, forKey: "pg.notify.stamp.serial")
        d.set(state, forKey: "pg.notify.stamp.state")
        d.set(jobId, forKey: "pg.notify.stamp.jobId")
    }

    static func saveAll(_ stamps: [String: PrintNotifyStamp], to d: UserDefaults) {
        let arr: [[String: String]] = stamps.values.map {
            ["serial": $0.serial, "state": $0.state, "jobId": $0.jobId]
        }
        d.set(arr, forKey: listKey)
        clear(d)
    }

    static func clear(_ d: UserDefaults) {
        d.removeObject(forKey: "pg.notify.stamp.serial")
        d.removeObject(forKey: "pg.notify.stamp.state")
        d.removeObject(forKey: "pg.notify.stamp.jobId")
    }
}

/// Decides print alerts from glance snapshot edges. Permission is requested on the first
/// RUNNING or PREPARE snapshot, not on FINISH, so the grant prompt cannot drop that alert.
/// State is keyed by printer serial so a focus change is not a print edge.
struct PrintNotify {
    var serial: String
    var prefs: PrintNotifyPrefs
    var stamps: [String: PrintNotifyStamp]
    var askedPermission = false
    var lastBySerial: [String: String] = [:]
    var timedBySerial: [String: Bool] = [:]

    var stamp: PrintNotifyStamp? {
        get { stamps[serial] }
        set { stamps[serial] = newValue }
    }

    init(serial: String, prefs: PrintNotifyPrefs, stamp: PrintNotifyStamp?) {
        self.serial = serial
        self.prefs = prefs
        if let stamp {
            self.stamps = [stamp.serial: stamp]
        } else {
            self.stamps = [:]
        }
    }

    init(serial: String, prefs: PrintNotifyPrefs, stamps: [String: PrintNotifyStamp]) {
        self.serial = serial
        self.prefs = prefs
        self.stamps = stamps
    }

    mutating func observe(_ content: GlanceContent) -> PrintNotifyOutcome {
        switch content.result {
        case let .doc(doc):
            var requestPermission = false
            var alerts: [PrintNotifyAlert] = []
            for printer in doc.printers {
                let one = observePrinter(printer)
                requestPermission = requestPermission || one.requestPermission
                alerts.append(contentsOf: one.alerts)
            }
            return PrintNotifyOutcome(requestPermission: requestPermission, alerts: alerts)
        case .feedDown:
            var alerts: [PrintNotifyAlert] = []
            let ids = Set(lastBySerial.keys).union(timedBySerial.keys)
            let keys = ids.isEmpty && !serial.isEmpty ? [serial] : Array(ids)
            for id in keys {
                let one = observeNamed(id, next: "FEEDDOWN", row: nil)
                alerts.append(contentsOf: one.alerts)
            }
            return PrintNotifyOutcome(requestPermission: false, alerts: alerts)
        default:
            // Connecting / setup: not a print edge and must not clear hadTimedJob.
            return PrintNotifyOutcome(requestPermission: false, alerts: [])
        }
    }

    private mutating func observePrinter(_ row: Printer) -> PrintNotifyOutcome {
        let next = row.state.uppercased()
        return observeNamed(row.id, next: next.isEmpty ? "OTHER" : next, row: row)
    }

    private mutating func observeNamed(
        _ id: String,
        next: String,
        row: Printer?
    ) -> PrintNotifyOutcome {
        var requestPermission = false
        if next == "RUNNING" || next == "PREPARE" {
            requestPermission = !askedPermission
            askedPermission = true
            stamps[id] = nil
        }

        let prev = lastBySerial[id]
        let hadTimed = timedBySerial[id] ?? false
        var alert: PrintNotifyAlert?
        if next == "FINISH", Self.isPrepareOrRunning(prev), prefs.finish {
            alert = Self.alert(.finish, row, serial: id)
        } else if next == "FAILED", Self.isPrepareOrRunning(prev), prefs.fail {
            alert = Self.alert(.fail, row, serial: id)
        } else if next == "PAUSE", Self.isPrepareOrRunning(prev), prefs.pause {
            alert = Self.alert(.pause, row, serial: id)
        } else if next == "OFFLINE", prefs.offline, Self.isOfflineEdge(prev: prev, hadTimedJob: hadTimed) {
            alert = Self.alert(.offline, row, serial: id)
        }

        if alert != nil {
            let candidate = PrintNotifyStamp(serial: id, state: next, jobId: row?.jobId ?? "")
            if stamps[id] == candidate {
                alert = nil
            } else {
                stamps[id] = candidate
            }
        }

        lastBySerial[id] = next
        switch next {
        case "RUNNING", "PREPARE", "PAUSE":
            timedBySerial[id] = true
        case "FEEDDOWN", "OFFLINE":
            break
        default:
            timedBySerial[id] = false
        }

        return PrintNotifyOutcome(requestPermission: requestPermission, alert: alert)
    }

    func persistStamp(_ d: UserDefaults) {
        PrintNotifyStamp.saveAll(stamps, to: d)
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

    private static func alert(_ kind: PrintNotifyKind, _ row: Printer?, serial: String) -> PrintNotifyAlert? {
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
        return PrintNotifyAlert(kind: kind, title: title, body: body, serial: serial)
    }
}
