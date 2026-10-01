import Foundation

/// One low-filament notice per printer, tray, and task while starting or printing.
struct FilamentAlert {
    static let thresholdPercent = 20

    struct Notice: Equatable, Sendable {
        var title: String
        var body: String
        var identifier: String
    }

    private var fired: Set<String> = []

    mutating func consider(
        serial: String,
        name: String,
        state: String,
        filament: String?,
        tray: Int?,
        remain: Int?,
        taskId: String?,
        enabled: Bool = true
    ) -> Notice? {
        guard enabled else { return nil }
        switch state.uppercased() {
        case "RUNNING", "PREPARE":
            break
        default:
            return nil
        }
        guard let tray, let remain, remain < Self.thresholdPercent else { return nil }
        let task = taskId ?? ""
        let key = "\(serial)|\(tray)|\(task)"
        if fired.contains(key) { return nil }
        fired.insert(key)
        let trimmed = filament?.trimmingCharacters(in: .whitespaces) ?? ""
        let material = trimmed.isEmpty ? "filament" : trimmed
        let who = name.isEmpty ? "Printer" : name
        return Notice(
            title: "Low filament",
            body: "\(who) is using \(material) at \(remain)%.",
            identifier: "filament.\(key)"
        )
    }
}

/// Where a spool should run out, from how fast its AMS percent falls against print progress.
struct Runout: Codable, Equatable, Sendable {
    /// Print progress, 0–99, when the spool should be empty.
    var percent: Int
    /// Clock time, rounded to 5 minutes. Nil while paused or when it is under 5 minutes away.
    var at: String?
    /// Under 5 minutes away.
    var soon = false
    /// Slot label, like A2.
    var tray: String?
    var name: String?
    var color: String?
    /// Another AMS slot with the same filament and color, which AMS backup may switch to.
    var backup: String?
}

/// Per printer and job, the AMS percent of each spool against print progress (`mc_percent`).
/// Progress, not the clock, so pauses and speed changes don't skew the rate.
struct RunoutTracker: Codable, Equatable {
    static let defaultsKey = "pg.runout"
    /// Guess only this many times further ahead than the progress the drops were measured over.
    /// Whole-percent progress puts each drop up to half a percent off, so a short measurement can
    /// only see a short way, which is enough for a nearly empty spool.
    static let maxReach = 3.0
    /// A rise this big is a new or refilled spool; smaller rises are the AMS estimate wobbling.
    static let swapRise = 3

    struct Spool: Codable, Equatable {
        var name: String?
        var color: String?
        /// Lowest percent seen this job.
        var low: Int
        /// Where `low` first showed.
        var lowAt: Double?
        /// Percent and progress right after the first drop. The rate counts from there, so the
        /// unknown fraction of a step at the first reading drops out.
        var first: Int?
        var firstAt: Double?
        /// Progress at the last reading. A drop lands halfway between this and the reading that shows it.
        var seenAt: Double
        /// The last reading, to spot a fall back to `low` after the estimate wobbles up.
        var last: Int?
    }

    struct Job: Codable, Equatable {
        var id: String
        var spools: [String: Spool] = [:]
        var noticed: Set<String> = []
    }

    var jobs: [String: Job] = [:]

    static func load(_ d: UserDefaults) -> RunoutTracker {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(RunoutTracker.self, from: $0) } ?? RunoutTracker()
    }

    func save(_ d: UserDefaults) {
        d.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// Records this report's spool percents and returns the earliest runout before the print ends.
    mutating func observe(
        _ row: Printer,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> Runout? {
        let state = row.state.uppercased()
        switch state {
        case "RUNNING", "PAUSE":
            break
        case "FINISH", "FAILED", "IDLE":
            jobs[row.id] = nil
            return nil
        default:
            // Starting or offline: keep what we have for when it prints again.
            return nil
        }
        guard let jobId = row.jobId, let percent = row.percent else { return nil }
        var job = jobs[row.id].flatMap { $0.id == jobId ? $0 : nil } ?? Job(id: jobId)
        let p = Double(percent)
        // Purge and calibration use filament at 0% progress, and a paused printer makes no progress.
        let counting = state == "RUNNING" && (row.layer ?? 0) >= 1
        let trays = (row.trays ?? []).filter { $0.remain != nil }
        job.spools = job.spools.filter { id, _ in trays.contains { $0.id == id } }
        for tray in trays {
            let remain = tray.remain ?? 0
            guard var s = job.spools[tray.id], s.name == tray.name, s.color == tray.color,
                  remain < s.low + Self.swapRise else {
                job.spools[tray.id] = Spool(name: tray.name, color: tray.color, low: remain, seenAt: p)
                continue
            }
            if remain < s.low {
                if counting {
                    let at = (s.seenAt + p) / 2
                    if s.first == nil {
                        s.first = remain
                        s.firstAt = at
                    }
                    s.lowAt = at
                    s.low = remain
                } else {
                    s = Spool(name: tray.name, color: tray.color, low: remain, seenAt: p)
                }
            } else if counting, remain == s.low, (s.last ?? remain) > remain, s.lowAt != nil {
                // Back down after a wobble up: the AMS was near the step, so the latest fall places it better.
                let at = (s.seenAt + p) / 2
                if s.first == s.low { s.firstAt = at }
                s.lowAt = at
            }
            s.last = remain
            s.seenAt = p
            job.spools[tray.id] = s
        }

        var best: (out: Double, tray: AMSTray)?
        for tray in trays {
            guard let s = job.spools[tray.id], let first = s.first, let firstAt = s.firstAt, let lowAt = s.lowAt,
                  first > s.low, lowAt - firstAt >= 1 else { continue }
            let span = lowAt - firstAt
            let rate = Double(first - s.low) / span
            // ponytail: treats the reading as empty at 0, so the guess can be up to one step early.
            // Early is the safe side; a per-model offset could tighten it once real runouts are logged.
            let ahead = Double(s.low) / rate
            let out = max(p, lowAt + ahead)
            if ahead <= span * Self.maxReach, out < 100, out < best?.out ?? 100 {
                best = (out, tray)
            }
        }
        jobs[row.id] = job
        guard let best else { return nil }

        var runout = Runout(
            percent: Int(best.out),
            tray: best.tray.label,
            name: best.tray.name,
            color: best.tray.color
        )
        if best.tray.unit != nil, let name = best.tray.name, let color = best.tray.color {
            runout.backup = row.trays?.first {
                $0.id != best.tray.id && $0.unit != nil && $0.name == name && $0.color == color
            }?.label
        }
        if state == "RUNNING", let remainingS = row.remainingS, remainingS > 0, percent < 100 {
            let s = Double(remainingS) * (best.out - p) / (100 - p)
            if s < 300 {
                runout.soon = true
            } else {
                let t = now.addingTimeInterval(s).timeIntervalSinceReferenceDate
                let rounded = Date(timeIntervalSinceReferenceDate: (t / 300).rounded() * 300)
                runout.at = GlanceContent.dayTime(rounded, now: now, calendar: calendar, locale: locale)
            }
        }
        return runout
    }

    /// True once per printer, job, and slot.
    mutating func shouldNotify(serial: String, runout: Runout) -> Bool {
        guard var job = jobs[serial] else { return false }
        let inserted = job.noticed.insert(runout.tray ?? "").inserted
        jobs[serial] = job
        return inserted
    }
}
