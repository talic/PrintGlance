import Foundation

/// Nine hours from `startHour` on this Mac's clock: the finished notice waits for the end, and
/// finishing soon is skipped inside.
struct QuietHours: Hashable, Sendable {
    /// 0–23. One of `starts`.
    var startHour: Int

    static let hours = 9
    /// The Notifications menu's choices: 9 PM, 10 PM, 11 PM, and midnight.
    static let starts = [21, 22, 23, 0]
    static let `default` = QuietHours(startHour: 22)

    /// 7 for a 10 PM start.
    var endHour: Int { (startHour + Self.hours) % 24 }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    /// Next `endHour`:00 local on or after `date`. If `date` is before `endHour`, that morning.
    func nextMorning(from date: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = endHour
        comps.minute = 0
        comps.second = 0
        let morning = calendar.date(from: comps) ?? date
        if calendar.component(.hour, from: date) < endHour {
            return morning
        }
        return calendar.date(byAdding: .day, value: 1, to: morning) ?? morning
    }

    /// When a Finished notice due at `now` shows: nil for now, or the window's end while inside it.
    func finishShowsAt(_ now: Date, calendar: Calendar = .current) -> DateComponents? {
        guard contains(now, calendar: calendar) else { return nil }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: nextMorning(from: now, calendar: calendar))
    }
}

enum ComingOffPhase: String, Equatable {
    case scheduled
    case done
}

struct ComingOffAction: Equatable {
    var identifier: String
    var cancelIds: [String]
    var interval: TimeInterval?
    var immediate: Bool
    var title: String
    /// The job, under the title. Empty when the printer gave no job name.
    var subtitle: String = ""
    var body: String

    static func cancelOnly(_ id: String) -> ComingOffAction {
        ComingOffAction(
            identifier: id,
            cancelIds: [id],
            interval: nil,
            immediate: false,
            title: "",
            body: ""
        )
    }
}

/// Once-per-job "Print finishing soon" banner, `PrintNotifyPrefs.comingOffLead` minutes before the end.
/// Not a `PrintNotify` state edge.
struct ComingOff: Equatable {
    static let jumpS = 120
    static let listKey = "pg.comingoff.phase"
    static let fireInKey = "pg.comingoff.fireAt"
    /// Held the delay from scheduling, which a steady print outran by a minute a minute. Dropped on
    /// save; a notice saved then has no fire time, so it reschedules once.
    static let oldFireInKey = "pg.comingoff.remain"

    var phase: [String: ComingOffPhase] = [:]
    /// When the scheduled notice fires, in whole seconds since 1970. It moves when the remaining
    /// time jumps or the lead time changes.
    // ponytail: named for the delay it used to hold, kept so #79 merges cleanly; rename it
    // `scheduledFireAt` once that lands.
    var scheduledFireInS: [String: Int] = [:]

    static func notificationId(serial: String, jobId: String) -> String {
        "pg.comingoff.\(serial).\(jobId)"
    }

    static func load(_ d: UserDefaults) -> ComingOff {
        var out = ComingOff()
        if let raw = d.dictionary(forKey: listKey) as? [String: String] {
            for (k, v) in raw {
                if let p = ComingOffPhase(rawValue: v) {
                    out.phase[k] = p
                }
            }
        }
        if let fireIn = d.dictionary(forKey: fireInKey) as? [String: Int] {
            out.scheduledFireInS = fireIn
        }
        return out
    }

    func save(_ d: UserDefaults) {
        var raw: [String: String] = [:]
        for (k, v) in phase {
            raw[k] = v.rawValue
        }
        d.set(raw, forKey: Self.listKey)
        d.removeObject(forKey: Self.oldFireInKey)
        d.set(scheduledFireInS, forKey: Self.fireInKey)
    }

    /// Finishing soon was turned off: the notices on their way, to cancel. Turned on again, a print still
    /// running gets its notice scheduled anew.
    mutating func cancelScheduled() -> [String] {
        var ids: [String] = []
        for (key, p) in phase where p == .scheduled {
            guard let bar = key.firstIndex(of: "|") else { continue }
            ids.append(Self.notificationId(serial: String(key[..<bar]), jobId: String(key[key.index(after: bar)...])))
            phase[key] = nil
            scheduledFireInS[key] = nil
        }
        return ids.sorted()
    }

    /// A removed printer: its scheduled notices, to cancel.
    mutating func forget(serial: String) -> [String] {
        var ids: [String] = []
        for key in Array(phase.keys) where key.hasPrefix("\(serial)|") {
            if phase[key] == .scheduled {
                ids.append(Self.notificationId(serial: serial, jobId: String(key.dropFirst(serial.count + 1))))
            }
            phase[key] = nil
            scheduledFireInS[key] = nil
        }
        return ids
    }

    mutating func consider(
        printer: Printer,
        prefs: PrintNotifyPrefs,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ComingOffAction? {
        let serial = printer.id
        let jobId = printer.jobId ?? ""
        let key = "\(serial)|\(jobId)"
        let id = Self.notificationId(serial: serial, jobId: jobId)
        let state = printer.printState

        var cancelIds: [String] = []
        for existing in Array(phase.keys) where existing.hasPrefix("\(serial)|") && existing != key {
            let jobId = String(existing.dropFirst(serial.count + 1))
            if phase[existing] == .scheduled {
                cancelIds.append(Self.notificationId(serial: serial, jobId: jobId))
            }
            phase[existing] = nil
            scheduledFireInS[existing] = nil
        }

        let action: ComingOffAction?
        switch state {
        case .printing:
            action = running(
                printer: printer,
                key: key,
                id: id,
                prefs: prefs,
                now: now,
                calendar: calendar
            )
        case .paused, .offline:
            action = pauseOrOffline(key: key, id: id)
        case .finished, .idle, .failed:
            action = complete(key: key, id: id)
        default:
            action = nil
        }

        if cancelIds.isEmpty {
            return action
        }
        if var action {
            action.cancelIds = Array(Set(action.cancelIds + cancelIds))
            return action
        }
        return ComingOffAction(
            identifier: cancelIds[0],
            cancelIds: cancelIds,
            interval: nil,
            immediate: false,
            title: "",
            body: ""
        )
    }

    private mutating func running(
        printer: Printer,
        key: String,
        id: String,
        prefs: PrintNotifyPrefs,
        now: Date,
        calendar: Calendar
    ) -> ComingOffAction? {
        guard prefs.comingOff, let remainingS = printer.remainingS else { return nil }
        if phase[key] == .done { return nil }

        let fireInS = max(0, remainingS - prefs.comingOffLead * 60)
        if let quiet = prefs.quietWindow, quiet.contains(now.addingTimeInterval(TimeInterval(fireInS)), calendar: calendar) {
            phase[key] = .done
            scheduledFireInS[key] = nil
            return ComingOffAction.cancelOnly(id)
        }

        let name = printer.name.isEmpty ? "Printer" : printer.name
        let title = "\(name) finishing soon"
        let subtitle = printer.job ?? ""
        // Already inside the lead time: say what is actually left.
        let minutes = fireInS > 0 ? prefs.comingOffLead : max(1, (remainingS + 59) / 60)
        let body = "About \(minutes) \(minutes == 1 ? "minute" : "minutes") left."

        // Compared as a date: the delay shrinks with the clock, the fire time doesn't. The printer
        // counts in whole minutes, so a steady print wobbles by under one. Every lead time is at
        // least 5 minutes from the next, so changing it moves the date past `jumpS` too.
        let fireAt = Int(now.timeIntervalSince1970.rounded()) + fireInS
        let pending = phase[key] == .scheduled ? scheduledFireInS[key] : nil

        if fireInS == 0 {
            phase[key] = .done
            scheduledFireInS[key] = nil
            // The notice already scheduled is due, or came: no second one.
            if let pending, pending - fireAt <= Self.jumpS { return nil }
            return ComingOffAction(
                identifier: id,
                cancelIds: [id],
                interval: nil,
                immediate: true,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }

        if let pending, abs(pending - fireAt) <= Self.jumpS {
            return nil
        }
        phase[key] = .scheduled
        scheduledFireInS[key] = fireAt
        return ComingOffAction(
            identifier: id,
            cancelIds: [id],
            interval: TimeInterval(fireInS),
            immediate: false,
            title: title,
            subtitle: subtitle,
            body: body
        )
    }

    private mutating func pauseOrOffline(key: String, id: String) -> ComingOffAction? {
        if phase[key] == .done { return nil }
        if phase[key] == .scheduled {
            phase[key] = nil
            scheduledFireInS[key] = nil
            return ComingOffAction.cancelOnly(id)
        }
        return nil
    }

    /// A job never seen printing has no notice to cancel, and is not marked done: the printer
    /// names the next job while it still says Finished (2026-11-10), and done would silence that
    /// job's notice for the whole print.
    private mutating func complete(key: String, id: String) -> ComingOffAction? {
        guard let had = phase[key] else { return nil }
        phase[key] = .done
        scheduledFireInS[key] = nil
        return had == .scheduled ? ComingOffAction.cancelOnly(id) : nil
    }
}
