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

/// Per printer and job, a straight-line fit of each spool's AMS percent against print progress
/// (`mc_percent`). Progress, not the clock, so pauses and speed changes don't skew it.
///
/// On an X2D (2026-10-01) the reading swung 3–5 for 15% of progress, then read 0–2 for the last
/// 20% of the print without running out. Counting drops took two dips as a rate 20 times too fast;
/// a fit with one reading per percent rides out the swings.
struct RunoutTracker: Codable, Equatable {
    static let defaultsKey = "pg.runout"
    /// Below this the reading is noise, and 0 still had filament, so readings under it are left
    /// out. The fit stops moving and the last guess made above it stands.
    static let floor = 5
    /// Guess only this many times further ahead than the progress the readings cover.
    static let maxReach = 3.0
    /// A rise this big is a new or refilled spool; smaller rises are the estimate swinging.
    static let swapRise = 10
    static let minReadings = 5.0

    /// One reading per whole percent of progress, kept as least-squares sums.
    struct Spool: Codable, Equatable {
        var name: String?
        var color: String?
        var n = 0.0, sp = 0.0, sr = 0.0, spp = 0.0, spr = 0.0, srr = 0.0
        var firstAt: Int?
        var lastAt: Int?
        /// The newest reading at progress `pendingAt`. It joins the sums once progress moves on.
        var pending: Int
        var pendingAt: Int

        init(name: String?, color: String?, remain: Int, at p: Int) {
            self.name = name
            self.color = color
            pending = remain
            pendingAt = p
        }

        mutating func add(_ p: Int, _ r: Int) {
            let (x, y) = (Double(p), Double(r))
            n += 1; sp += x; sr += y; spp += x * x; spr += x * y; srr += y * y
            if firstAt == nil { firstAt = p }
            lastAt = p
        }

        /// Progress where the line reaches 0, when it falls clearly (slope two standard errors
        /// below flat) and doesn't reach past `maxReach` times the progress it covers.
        var runoutAt: Double? {
            guard n >= RunoutTracker.minReadings, let firstAt, let lastAt else { return nil }
            let sxx = spp - sp * sp / n
            guard sxx > 0 else { return nil }
            let b = (spr - sp * sr / n) / sxx
            let a = (sr - b * sp) / n
            let se = (max(srr - a * sr - b * spr, 0) / (n - 2) / sxx).squareRoot()
            guard b + 2 * se < 0 else { return nil }
            let out = -a / b
            return out - Double(lastAt) <= Double(lastAt - firstAt) * RunoutTracker.maxReach ? out : nil
        }
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
        let trays = (row.trays ?? []).filter { $0.remain != nil }
        job.spools = job.spools.filter { id, _ in trays.contains { $0.id == id } }
        for tray in trays {
            let remain = tray.remain ?? 0
            guard var s = job.spools[tray.id], s.name == tray.name, s.color == tray.color,
                  remain < s.pending + Self.swapRise else {
                job.spools[tray.id] = Spool(name: tray.name, color: tray.color, remain: remain, at: percent)
                continue
            }
            // One reading per percent: purging at 0% and a pause add nothing, as progress stands still.
            if percent > s.pendingAt, s.pending >= Self.floor {
                s.add(s.pendingAt, s.pending)
            }
            s.pending = remain
            s.pendingAt = percent
            job.spools[tray.id] = s
        }
        jobs[row.id] = job

        let p = Double(percent)
        var best: (out: Double, tray: AMSTray)?
        for tray in trays {
            // ponytail: treats a reading of 0 as empty, though the X2D printed on at 0. Once spools
            // are weighed at 0, an offset per AMS model could move the guess later.
            // Past the guess and still printing means it was wrong, so it goes.
            guard let out = job.spools[tray.id]?.runoutAt, out >= p, out < 100, out < best?.out ?? 100 else { continue }
            best = (out, tray)
        }
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
