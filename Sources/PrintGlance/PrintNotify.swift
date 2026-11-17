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
    /// Alerts still waiting to be delivered that are no longer true: a finish Quiet Hours holds for the morning.
    var unsent: [String] = []

    var alert: PrintNotifyAlert? { alerts.first }
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

/// Decides print alerts from each printer's state changes. Permission is requested on the first
/// RUNNING or PREPARE row, not on FINISH, so the grant prompt cannot drop that alert.
/// State is kept per printer serial, so a focus change is not a print edge. A relaunch starts with no
/// last state, so a printer already Finished or Paused is not an edge either.
struct PrintNotify {
    var prefs: PrintNotifyPrefs
    var askedPermission = false
    var lastBySerial: [String: String] = [:]

    init(prefs: PrintNotifyPrefs) {
        self.prefs = prefs
    }

    /// Duplicate-alert stamps, saved by older builds. Edges already allow one alert per change, so they are dropped.
    static func forgetStamps(_ d: UserDefaults) {
        for key in ["pg.notify.stamps", "pg.notify.stamp.serial", "pg.notify.stamp.state", "pg.notify.stamp.jobId"] {
            d.removeObject(forKey: key)
        }
    }

    mutating func observe(_ content: GlanceContent) -> PrintNotifyOutcome {
        // Connecting, setup, and no printer reachable before any report: not print edges.
        guard case let .doc(doc) = content.result else {
            return PrintNotifyOutcome(requestPermission: false, alerts: [])
        }
        var requestPermission = false
        var alerts: [PrintNotifyAlert] = []
        var clears: [String] = []
        var unsent: [String] = []
        for printer in doc.printers {
            let one = observe(printer)
            requestPermission = requestPermission || one.requestPermission
            alerts.append(contentsOf: one.alerts)
            clears.append(contentsOf: one.clears)
            unsent.append(contentsOf: one.unsent)
        }
        return PrintNotifyOutcome(requestPermission: requestPermission, alerts: alerts, clears: clears, unsent: unsent)
    }

    private mutating func observe(_ row: Printer) -> PrintNotifyOutcome {
        let id = row.id
        let next = row.state.uppercased()
        let printing = next == "RUNNING" || next == "PREPARE"
        let requestPermission = printing && !askedPermission
        if printing { askedPermission = true }

        let prev = lastBySerial[id]
        let wasPrinting = prev == "RUNNING" || prev == "PREPARE"
        var alert: PrintNotifyAlert?
        if next == "FINISH", wasPrinting, prefs.finish {
            alert = Self.alert(.finish, row)
        } else if next == "FAILED", wasPrinting, prefs.fail {
            alert = Self.alert(.fail, row)
        } else if next == "PAUSE", wasPrinting, prefs.pause {
            alert = Self.alert(.pause, row)
        } else if next == "OFFLINE", wasPrinting || prev == "PAUSE", prefs.offline {
            alert = Self.alert(.offline, row)
        }

        let clears = prev == next ? [] : Self.clears(id, next: next)
        // A new print makes a finish held for the morning old news, like the delivered one.
        let finished = PrintNotifyAlert.identifier(.finish, serial: id)
        let unsent = clears.contains(finished) ? [finished] : []
        lastBySerial[id] = next
        return PrintNotifyOutcome(
            requestPermission: requestPermission,
            alerts: alert.map { [$0] } ?? [],
            clears: clears,
            unsent: unsent
        )
    }

    /// A printer that was removed or now has a new connection: its next row starts over, not an edge.
    mutating func forget(_ serial: String) {
        lastBySerial[serial] = nil
    }

    /// What a new state makes untrue. A new or resumed print ends the last finish, pause, or failure,
    /// and any report at all ends a lost connection. Also runs on the first report after launch.
    private static func clears(_ id: String, next: String) -> [String] {
        var kinds: [PrintNotifyKind] = []
        if next == "RUNNING" || next == "PREPARE" {
            kinds = [.finish, .pause, .fail]
        }
        if next != "OFFLINE" {
            kinds.append(.offline)
        }
        return kinds.map { PrintNotifyAlert.identifier($0, serial: id) }
    }

    /// Mac network changes this long ago or less explain a lost connection.
    static let networkSettle: TimeInterval = 120

    /// False when this Mac caused the lost connection: it has no network, or its network just changed.
    static func offlineAlertAllowed(macOnline: Bool, networkChangedAt: Date?, now: Date) -> Bool {
        guard macOnline else { return false }
        guard let networkChangedAt else { return true }
        return now.timeIntervalSince(networkChangedAt) >= networkSettle
    }

    /// "X2D paused" over "Benchy · 62%" over the reason. The code shows only when there's no reason:
    /// the card lists every code with a Look up link.
    private static func alert(_ kind: PrintNotifyKind, _ row: Printer) -> PrintNotifyAlert {
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
        return PrintNotifyAlert(kind: kind, title: title, subtitle: subtitle, body: body, serial: row.id)
    }
}
