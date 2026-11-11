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

/// How fast a print really moves: seconds of printing per percent, by the clock.
///
/// A melt rate is grams per real hour, so it is measured, not taken from the printer's time
/// left, which is the slicer's guess.
struct Pace: Codable, Equatable {
    /// Percents the clock must cover before it counts.
    static let minSpan = 3
    /// Faster than 100% in five minutes is a burst of old reports, not a print.
    static let fastest = 3.0

    var fromPercent: Int
    var from: Date
    var toPercent: Int
    var to: Date
    /// False until the percent first moves, so the clock starts on a whole percent.
    var anchored = false
    var pausedS = 0.0
    var pausedAt: Date? = nil

    init(percent: Int, now: Date) {
        fromPercent = percent
        from = now
        toPercent = percent
        to = now
    }

    mutating func printing(_ percent: Int, now: Date) {
        if let pausedAt {
            pausedS += max(0, now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
        guard percent > toPercent else { return }
        if !anchored {
            self = Pace(percent: percent, now: now)
            anchored = true
        }
        toPercent = percent
        to = now
    }

    mutating func paused(now: Date) {
        if anchored, pausedAt == nil { pausedAt = now }
    }

    // ponytail: a pause the app slept through counts as printing. Reading the printer's own
    // print clock, if a firmware sends one, would fix it.
    var secondsPerPercent: Double? {
        let span = toPercent - fromPercent
        guard span >= Self.minSpan else { return nil }
        let s = (to.timeIntervalSince(from) - pausedS) / Double(span)
        return s >= Self.fastest ? s : nil
    }
}

/// Per printer and job, where each spool should run out, from its AMS percent against print
/// progress (`mc_percent`).
///
/// The AMS percent is a gauge, not a count. On 2026-11-10 a spool near 50% read 58, then 47
/// within ten minutes, then 50, all while feeding, and a second printer's rose 4 points as it fed.
/// A nearly empty one (2026-10-01) swung 3–5, then read 0–2 for the last 20% of the print without
/// running out. A line fitted to a few readings takes one swing for the spool emptying. So the
/// fit only speaks when:
///
/// - the line falls by `swingFactor` times the swing of the readings around it,
/// - the fall is one a nozzle can melt (`maxGramsPerHour`), at the print's own `Pace`,
/// - the end is no further ahead than `maxReach` times the progress the readings cover.
///
/// It says less than a plain fit and says it later. A missed runout still pauses the print and
/// sends Print Paused; a wrong one sends you to a spool that is half full.
struct RunoutTracker: Codable, Equatable {
    static let defaultsKey = "pg.runout"
    /// Below this the reading is noise, and 0 still had filament, so readings under it are left
    /// out. The fit stops moving and the last guess made above it stands.
    static let floor = 5
    /// Guess only this many times further ahead than the progress the readings cover. A spool
    /// has then lost a third of what it started the print with.
    static let maxReach = 2.0
    /// A rise this big is a new or refilled spool; smaller rises are the gauge swinging.
    static let swapRise = 10
    static let minReadings = 8
    /// The fitted fall must be this many times the readings' swing around the line.
    static let swingFactor = 2.0
    /// Whole-number readings swing this much around a clean line.
    static let minSwing = 2.0
    /// 30 mm³/s of PLA for an hour. A fast nozzle peaks above that; no print averages it.
    // ponytail: one limit for every nozzle. A 0.8 mm high-flow nozzle can pass it, and then a
    // real runout goes unsaid. Scaling by `nozzle_diameter` from the report would lift it.
    static let maxGramsPerHour = 134.0
    /// Bambu spools hold 1 kg unless the tag says otherwise.
    static let defaultGrams = 1000

    struct Reading: Codable, Equatable {
        /// Print progress, 0–100.
        var p: Int
        /// Spool percent.
        var r: Int
    }

    struct Spool: Codable, Equatable {
        var name: String?
        var color: String?
        /// One reading per whole percent of progress, oldest first.
        var readings: [Reading] = []
        /// The newest reading at progress `pendingAt`. It joins `readings` once progress moves on.
        var pending: Int
        var pendingAt: Int

        init(name: String?, color: String?, remain: Int, at p: Int) {
            self.name = name
            self.color = color
            pending = remain
            pendingAt = p
        }

        /// Progress where the fitted line reaches 0, or nil while the readings don't settle it.
        func runoutAt(secondsPerPercent: Double, grams: Int) -> Double? {
            guard readings.count >= RunoutTracker.minReadings, secondsPerPercent > 0,
                  let first = readings.first?.p, let last = readings.last?.p else { return nil }
            let n = Double(readings.count)
            var sp = 0.0, sr = 0.0, spp = 0.0, spr = 0.0
            for reading in readings {
                let (x, y) = (Double(reading.p), Double(reading.r))
                sp += x; sr += y; spp += x * x; spr += x * y
            }
            let sxx = spp - sp * sp / n
            guard sxx > 0 else { return nil }
            let b = (spr - sp * sr / n) / sxx
            let a = (sr - b * sp) / n
            guard b < 0 else { return nil }

            let residuals = readings.map { Double($0.r) - (a + b * Double($0.p)) }
            let swing = max((residuals.max() ?? 0) - (residuals.min() ?? 0), RunoutTracker.minSwing)
            let span = Double(last - first)
            guard -b * span >= RunoutTracker.swingFactor * swing else { return nil }

            let gramsPerHour = -b * Double(grams) / 100 * 3600 / secondsPerPercent
            guard gramsPerHour <= RunoutTracker.maxGramsPerHour else { return nil }

            let out = -a / b
            return out - Double(last) <= span * RunoutTracker.maxReach ? out : nil
        }
    }

    struct Job: Codable, Equatable {
        var id: String
        var spools: [String: Spool] = [:]
        var noticed: Set<String> = []
        var pace: Pace? = nil
    }

    var jobs: [String: Job] = [:]

    /// A fit saved by an older build doesn't decode, so that print starts over.
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
        if state == "RUNNING" {
            if job.pace == nil { job.pace = Pace(percent: percent, now: now) }
            job.pace?.printing(percent, now: now)
        } else {
            job.pace?.paused(now: now)
        }
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
                s.readings.append(Reading(p: s.pendingAt, r: s.pending))
            }
            s.pending = remain
            s.pendingAt = percent
            job.spools[tray.id] = s
        }
        jobs[row.id] = job

        // The clock once it has covered enough of the print; until then, the printer's word.
        var pace = job.pace?.secondsPerPercent
        if pace == nil, let remainingS = row.remainingS, remainingS > 0, percent < 100 {
            pace = Double(remainingS) / Double(100 - percent)
        }
        guard let pace else { return nil }

        let p = Double(percent)
        var best: (out: Double, tray: AMSTray)?
        for tray in trays {
            let grams = tray.weight.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultGrams
            // ponytail: treats a reading of 0 as empty, though the X2D printed on at 0. Once spools
            // are weighed at 0, an offset per AMS model could move the guess later.
            // Past the guess and still printing means it was wrong, so it goes.
            guard let out = job.spools[tray.id]?.runoutAt(secondsPerPercent: pace, grams: grams),
                  out >= p, out < 100, out < best?.out ?? 100 else { continue }
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
        if state == "RUNNING" {
            let s = (best.out - p) * pace
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
