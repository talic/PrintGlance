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
    /// The job and how far it got, under the title. Empty when there's nothing to say.
    var subtitle: String = ""
    var body: String
    var serial: String

    var identifier: String { Self.identifier(kind, serial: serial) }

    /// One per printer and kind, so a newer alert replaces the older one in Notification Center.
    static func identifier(_ kind: PrintNotifyKind, serial: String) -> String {
        "pg.\(kind.rawValue).\(serial.isEmpty ? "printer" : serial)"
    }
}

struct PrintNotifyOutcome: Equatable {
    var requestPermission: Bool
    var alerts: [PrintNotifyAlert]
    /// Delivered alerts that are no longer true, to take out of Notification Center.
    var clears: [String] = []

    var alert: PrintNotifyAlert? { alerts.first }

    init(requestPermission: Bool, alert: PrintNotifyAlert?, clears: [String] = []) {
        self.requestPermission = requestPermission
        self.alerts = alert.map { [$0] } ?? []
        self.clears = clears
    }

    init(requestPermission: Bool, alerts: [PrintNotifyAlert], clears: [String] = []) {
        self.requestPermission = requestPermission
        self.alerts = alerts
        self.clears = clears
    }
}

struct PrintNotifyPrefs: Equatable {
    var finish: Bool
    var fail: Bool
    var pause: Bool
    var offline: Bool
    var comingOff: Bool
    var quietHours: Bool
    var lowFilament: Bool = true
    /// Minutes before the end that "Print finishing soon" arrives. One of `comingOffLeads`.
    var comingOffLead: Int = 10

    static let comingOffLeads = [5, 10, 15, 30]

    static let `default` = PrintNotifyPrefs(
        finish: true,
        fail: true,
        pause: true,
        offline: true,
        comingOff: true,
        quietHours: false
    )

    /// Pause alerts became default-on. Prefs save as a block, so an old explicit "off"
    /// looks the same as the old default; this turns pause on once for everyone.
    static let pauseOnKey = "pg.notify.pauseOn.v1"

    static func load(_ d: UserDefaults) -> PrintNotifyPrefs {
        if !d.bool(forKey: pauseOnKey) {
            d.set(true, forKey: "pg.notify.pause")
            d.set(true, forKey: pauseOnKey)
        }
        func flag(_ key: String, fallback: Bool) -> Bool {
            guard d.object(forKey: key) != nil else { return fallback }
            return d.bool(forKey: key)
        }
        let lead = d.integer(forKey: "pg.notify.comingOffLead")
        return PrintNotifyPrefs(
            finish: flag("pg.notify.finish", fallback: true),
            fail: flag("pg.notify.fail", fallback: true),
            pause: flag("pg.notify.pause", fallback: true),
            offline: flag("pg.notify.offline", fallback: true),
            comingOff: flag("pg.notify.comingOff", fallback: true),
            quietHours: flag("pg.notify.quietHours", fallback: false),
            lowFilament: flag("pg.notify.lowFilament", fallback: true),
            comingOffLead: comingOffLeads.contains(lead) ? lead : 10
        )
    }

    func save(_ d: UserDefaults) {
        d.set(finish, forKey: "pg.notify.finish")
        d.set(fail, forKey: "pg.notify.fail")
        d.set(pause, forKey: "pg.notify.pause")
        d.set(offline, forKey: "pg.notify.offline")
        d.set(comingOff, forKey: "pg.notify.comingOff")
        d.set(quietHours, forKey: "pg.notify.quietHours")
        d.set(lowFilament, forKey: "pg.notify.lowFilament")
        d.set(comingOffLead, forKey: "pg.notify.comingOffLead")
    }
}

/// The printer a clicked notification named. The next panel open shows it, once.
struct PendingSelection: Equatable {
    /// Every notification carries its printer's serial under this `userInfo` key.
    static let serialKey = "serial"

    var serial: String?

    mutating func take() -> String? {
        defer { serial = nil }
        return serial
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
            var clears: [String] = []
            for printer in doc.printers {
                let one = observePrinter(printer)
                requestPermission = requestPermission || one.requestPermission
                alerts.append(contentsOf: one.alerts)
                clears.append(contentsOf: one.clears)
            }
            return PrintNotifyOutcome(requestPermission: requestPermission, alerts: alerts, clears: clears)
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

        let clears = prev == next ? [] : Self.clears(id, next: next)
        lastBySerial[id] = next
        switch next {
        case "RUNNING", "PREPARE", "PAUSE":
            timedBySerial[id] = true
        case "FEEDDOWN", "OFFLINE":
            break
        default:
            timedBySerial[id] = false
        }

        return PrintNotifyOutcome(requestPermission: requestPermission, alert: alert, clears: clears)
    }

    /// What a new state makes untrue. A new or resumed print ends the last finish, pause, or failure,
    /// and any report at all ends a lost connection. Also runs on the first report after launch.
    private static func clears(_ id: String, next: String) -> [String] {
        var kinds: [PrintNotifyKind] = []
        if next == "RUNNING" || next == "PREPARE" {
            kinds = [.finish, .pause, .fail]
        }
        if next != "OFFLINE", next != "FEEDDOWN" {
            kinds.append(.offline)
        }
        return kinds.map { PrintNotifyAlert.identifier($0, serial: id) }
    }

    func persistStamp(_ d: UserDefaults) {
        PrintNotifyStamp.saveAll(stamps, to: d)
    }

    /// Mac network changes this long ago or less explain a lost connection.
    static let networkSettle: TimeInterval = 120

    /// False when this Mac caused the lost connection: it has no network, or its network just changed.
    static func offlineAlertAllowed(macOnline: Bool, networkChangedAt: Date?, now: Date) -> Bool {
        guard macOnline else { return false }
        guard let networkChangedAt else { return true }
        return now.timeIntervalSince(networkChangedAt) >= networkSettle
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

    /// "X2D paused" over "Benchy · 62%" over the reason. The code shows only when there's no reason:
    /// the card lists every code with a Look up link.
    private static func alert(_ kind: PrintNotifyKind, _ row: Printer?, serial: String) -> PrintNotifyAlert? {
        guard let row else { return nil }
        let name = row.name.isEmpty ? "Printer" : row.name
        let job = row.job.flatMap { $0.isEmpty ? nil : $0 }
        let progress = row.percent.flatMap { $0 > 0 ? "\($0)%" : nil }
        let title: String
        var subtitle = [job, progress].compactMap { $0 }.joined(separator: " · ")
        let body: String
        switch kind {
        case .finish:
            title = "\(name) finished"
            subtitle = job ?? ""
            body = "Ready to take off the plate."
        case .fail, .pause:
            title = kind == .fail ? "\(name) failed" : "\(name) paused"
            body = GlanceContent.leadErrorCode(row).map(GlanceContent.errorLine(code:)) ?? "The printer didn't say why."
        case .offline:
            title = "Lost connection to \(name)"
            subtitle = ""
            body = (row.percent.map { "\(job ?? name) was at \($0)%. " } ?? "") + "PrintGlance keeps trying."
        }
        return PrintNotifyAlert(kind: kind, title: title, subtitle: subtitle, body: body, serial: serial)
    }
}
