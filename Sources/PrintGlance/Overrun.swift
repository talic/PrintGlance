import Foundation

/// How long a printer runs past its own time left, learned from the prints the app watches finish.
///
/// The printer's time left ends with the last layer. Two dual-nozzle printers (2026-11-10) read 0
/// for the last two minutes of printing, then spent three more unloading before they reported
/// Finished: 4.6 and 5.1 minutes after the last time left they gave. Mid-print the time left kept
/// pace with the clock, so the gap is added, not scaled.
struct Overrun: Codable, Equatable {
    static let defaultsKey = "pg.overrun"
    /// Prints remembered per printer. The middle one counts, so one odd print doesn't move it.
    static let keep = 5
    /// Later than this and the app missed the end, or the print sat waiting.
    static let longestS = 900.0

    /// The last time left a printer gave above zero, and when it first gave it.
    struct Promise: Equatable {
        var jobId: String
        var remainingS: Int
        var at: Date
        /// Paused since: the finish says nothing about how late the printer runs.
        var paused = false

        var end: Date { at.addingTimeInterval(TimeInterval(remainingS)) }
    }

    /// Seconds late per printer, newest last.
    var late: [String: [Double]] = [:]
    /// Not saved: a relaunch in a print's last minutes skips that print.
    var promises: [String: Promise] = [:]

    private enum CodingKeys: String, CodingKey {
        case late
    }

    static func load(_ d: UserDefaults) -> Overrun {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Overrun.self, from: $0) } ?? Overrun()
    }

    func save(_ d: UserDefaults) {
        d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// Whole seconds this printer runs late: the middle of its remembered prints, 0 before the first.
    func lateBy(_ id: String) -> Int {
        let sorted = (late[id] ?? []).sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return Int(sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2)
    }

    /// Learns from a finish, and moves the row's time left and finish time to when the printer
    /// should report Finished.
    mutating func observe(
        _ row: inout Printer,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) {
        let state = row.state.uppercased()
        let jobId = row.jobId ?? ""
        switch state {
        case "RUNNING":
            if let s = row.remainingS, s > 0 {
                let last = promises[row.id]
                if last?.jobId != jobId || last?.remainingS != s || last?.paused == true {
                    promises[row.id] = Promise(jobId: jobId, remainingS: s, at: now)
                }
            }
        case "PAUSE":
            promises[row.id]?.paused = true
        case "FINISH":
            if let promise = promises[row.id], promise.jobId == jobId, !promise.paused {
                let s = now.timeIntervalSince(promise.end)
                if (0...Self.longestS).contains(s) {
                    late[row.id] = Array(((late[row.id] ?? []) + [s]).suffix(Self.keep))
                }
            }
            promises[row.id] = nil
            return
        case "FAILED", "IDLE":
            promises[row.id] = nil
            return
        case "PREPARE", "OFFLINE":
            break
        default:
            return
        }

        let lag = lateBy(row.id)
        guard lag > 0 else { return }
        if let s = row.remainingS, s > 0 {
            row.remainingS = s + lag
            row.eta = BambuPrint.etaHM(state: state, remainingS: row.remainingS, now: now, calendar: calendar, locale: locale)
        } else if state == "RUNNING", let promise = promises[row.id], promise.jobId == jobId, !promise.paused {
            // The time left has run out and the printer is still going: count down to where its
            // last one pointed. Whole minutes, so the row changes once a minute, not every report.
            let finish = promise.end.addingTimeInterval(TimeInterval(lag))
            let left = finish.timeIntervalSince(now)
            guard left > 0 else { return }
            row.remainingS = Int((left / 60).rounded(.up)) * 60
            row.eta = GlanceContent.dayTime(finish, now: now, calendar: calendar, locale: locale)
        }
    }
}
