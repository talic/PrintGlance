import Foundation

enum QuietHours {
    static let startHour = 22
    static let endHour = 7

    static func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= startHour || hour < endHour
    }

    /// Next 7 AM local on or after `date`. If `date` is before 7 AM, that morning.
    static func nextMorning(from date: Date, calendar: Calendar = .current) -> Date {
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
    /// Before lead times this key held the remaining time; a notice saved then reschedules once.
    static let fireInKey = "pg.comingoff.remain"

    var phase: [String: ComingOffPhase] = [:]
    /// Seconds from scheduling to the notice. It moves when the remaining time jumps or the lead time changes.
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
        d.set(scheduledFireInS, forKey: Self.fireInKey)
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
        let state = printer.state.uppercased()

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
        case "RUNNING":
            action = running(
                printer: printer,
                key: key,
                id: id,
                prefs: prefs,
                now: now,
                calendar: calendar
            )
        case "PAUSE", "OFFLINE":
            action = pauseOrOffline(key: key, id: id)
        case "FINISH", "IDLE", "FAILED":
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
        if prefs.quietHours, QuietHours.contains(now.addingTimeInterval(TimeInterval(fireInS)), calendar: calendar) {
            phase[key] = .done
            scheduledFireInS[key] = nil
            return ComingOffAction.cancelOnly(id)
        }

        let title = "Print finishing soon"
        let name = printer.name.isEmpty ? "Printer" : printer.name
        // Already inside the lead time: say what is actually left.
        let minutes = fireInS > 0 ? prefs.comingOffLead : max(1, (remainingS + 59) / 60)
        let left = "About \(minutes) \(minutes == 1 ? "minute" : "minutes") left."
        let body: String
        if let job = printer.job, !job.isEmpty {
            body = "\(job) on \(name). \(left)"
        } else {
            body = "\(name). \(left)"
        }

        if fireInS == 0 {
            phase[key] = .done
            scheduledFireInS[key] = nil
            return ComingOffAction(
                identifier: id,
                cancelIds: [id],
                interval: nil,
                immediate: true,
                title: title,
                body: body
            )
        }

        if phase[key] == .scheduled {
            let prev = scheduledFireInS[key] ?? fireInS
            if abs(prev - fireInS) <= Self.jumpS {
                return nil
            }
        }
        phase[key] = .scheduled
        scheduledFireInS[key] = fireInS
        return ComingOffAction(
            identifier: id,
            cancelIds: [id],
            interval: TimeInterval(fireInS),
            immediate: false,
            title: title,
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

    private mutating func complete(key: String, id: String) -> ComingOffAction? {
        let had = phase[key]
        phase[key] = .done
        scheduledFireInS[key] = nil
        if had == .scheduled || had == nil {
            return ComingOffAction.cancelOnly(id)
        }
        return nil
    }
}
