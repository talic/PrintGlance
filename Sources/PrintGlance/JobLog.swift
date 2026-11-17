import Foundation

struct JobLogRow: Codable, Equatable, Sendable, Identifiable {
    var serial: String
    var name: String
    var jobId: String
    var job: String?
    /// Every filament the print used, comma-separated, in the order each first fed.
    var filament: String?
    var startAt: Date
    var endedAt: Date?
    var outcome: String?
    /// One entry per pause PrintGlance saw: the code the printer gave, or "" for none.
    var pauses: [String]? = nil
    /// The code a failed print stopped with.
    var failCode: String? = nil
    /// Whether PrintGlance saw the job begin: Starting, or Printing at 1% or less. False for a print first
    /// seen part-way through, whose `startAt` is only when PrintGlance noticed it. Nil on older rows.
    var sawStart: Bool? = nil

    /// How long the print took, only when PrintGlance saw both ends. A print first seen part-way
    /// through would read short. Older rows, which didn't record it, keep their duration.
    var duration: TimeInterval? {
        guard let endedAt, sawStart != false else { return nil }
        return max(0, endedAt.timeIntervalSince(startAt))
    }

    var id: String {
        "\(serial)|\(jobId)|\(startAt.timeIntervalSince1970)"
    }

    var isOpen: Bool { outcome == nil }
}

struct JobLog {
    static let cap = 50
    static let outcomeOK = "ok"
    static let outcomeFail = "fail"

    /// On-disk shape of jobs.json.
    private struct Envelope: Codable { var rows: [JobLogRow] }

    var rows: [JobLogRow] = []
    /// Process-local. Not written to disk.
    var hadTimed: [String: Bool] = [:]
    /// Each printer's last state it reported, process-local, so a pause counts once and a relaunch doesn't
    /// recount it. Offline isn't one: a pause seen right after a reconnect happened while printing.
    var lastState: [String: PrintState] = [:]

    static func fileURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrintGlance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }

    static func load(from url: URL) -> JobLog {
        guard let data = try? Data(contentsOf: url) else { return JobLog() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let env = try? dec.decode(Envelope.self, from: data) else { return JobLog() }
        return JobLog(rows: env.rows)
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Envelope(rows: rows)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    mutating func observe(printers: [Printer], now: Date = Date()) {
        for printer in printers {
            observeOne(printer, now: now)
        }
        trim()
    }

    /// Forgets ended prints. An open row stays: dropping it would make the next report reopen the
    /// print with the wrong start time.
    mutating func clearEnded() {
        rows.removeAll { !$0.isOpen }
    }

    /// A removed printer's print in progress, which would otherwise stay open for good.
    mutating func forgetOpen(serial: String) {
        rows.removeAll { $0.serial == serial && $0.isOpen }
        hadTimed[serial] = nil
        lastState[serial] = nil
    }

    func recent(_ n: Int) -> [JobLogRow] {
        Array(rows.prefix(n))
    }

    func occupancyEndedAt(serial: String, state: String, jobId: String?) -> Date? {
        occupancyRow(serial: serial, state: state, jobId: jobId)?.endedAt
    }

    /// When the print behind `occupancyEndedAt` started, for "Took 4h 43m". Nil when its end wasn't seen.
    func occupancyStartedAt(serial: String, state: String, jobId: String?) -> Date? {
        occupancyRow(serial: serial, state: state, jobId: jobId).flatMap { $0.duration == nil ? nil : $0.startAt }
    }

    /// The newest finished row for a printer that shows Finished.
    private func occupancyRow(serial: String, state: String, jobId: String?) -> JobLogRow? {
        guard PrintState(state) == .finished else { return nil }
        let id = jobId ?? ""
        return rows.first { row in
            row.serial == serial
                && row.outcome == Self.outcomeOK
                && (id.isEmpty || row.jobId.isEmpty || row.jobId == id)
        }
    }

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines = ["started,ended,duration_min,printer,job,filament,outcome"]
        for row in rows {
            let started = iso.string(from: row.startAt)
            let ended = row.endedAt.map { iso.string(from: $0) } ?? ""
            let duration = row.duration.map { "\(Int($0 / 60))" } ?? ""
            lines.append(
                [
                    started,
                    ended,
                    duration,
                    csvEscape(row.name),
                    csvEscape(row.job ?? ""),
                    csvEscape(row.filament ?? ""),
                    row.outcome ?? "",
                ].joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func observeOne(_ printer: Printer, now: Date) {
        let next = printer.printState
        let jobId = printer.jobId ?? ""
        let prev = lastState[printer.id]
        if next != .offline { lastState[printer.id] = next }
        switch next {
        case .printing, .starting:
            hadTimed[printer.id] = true
            if let i = openIndex(serial: printer.id),
               !rows[i].jobId.isEmpty, !jobId.isEmpty, rows[i].jobId != jobId
            {
                rows[i].outcome = Self.outcomeOK
            }
            openOrUpdate(printer, jobId: jobId, now: now)
        case .finished:
            close(
                serial: printer.id,
                jobId: jobId,
                outcome: Self.outcomeOK,
                now: now,
                live: hadTimed[printer.id] == true
            )
            hadTimed[printer.id] = false
        case .paused:
            if prev?.isActive == true, let i = openIndex(serial: printer.id, jobId: jobId) {
                rows[i].pauses = (rows[i].pauses ?? []) + [GlanceContent.leadErrorCode(printer) ?? ""]
            }
        case .failed:
            close(
                serial: printer.id,
                jobId: jobId,
                outcome: Self.outcomeFail,
                now: now,
                live: hadTimed[printer.id] == true,
                failCode: GlanceContent.leadErrorCode(printer)
            )
            hadTimed[printer.id] = false
        case .idle:
            close(
                serial: printer.id,
                jobId: jobId,
                outcome: Self.outcomeOK,
                now: now,
                live: false
            )
            hadTimed[printer.id] = false
        default:
            break
        }
    }

    private mutating func openOrUpdate(_ printer: Printer, jobId: String, now: Date) {
        if let i = openIndex(serial: printer.id, jobId: jobId) {
            if rows[i].jobId.isEmpty, !jobId.isEmpty {
                rows[i].jobId = jobId
            }
            if let job = printer.job, !job.isEmpty { rows[i].job = job }
            if let fil = printer.filament, !fil.isEmpty { rows[i].filament = Self.adding(fil, to: rows[i].filament) }
            rows[i].name = printer.name
            return
        }
        rows.insert(
            JobLogRow(
                serial: printer.id,
                name: printer.name,
                jobId: jobId,
                job: printer.job,
                filament: printer.filament,
                startAt: now,
                endedAt: nil,
                outcome: nil,
                sawStart: printer.printState == .starting || (printer.percent ?? 0) <= 1
            ),
            at: 0
        )
    }

    /// Each filament a print used, in the order it first fed: "PLA Basic, PETG HF". A multi-color print
    /// changes spools many times; the list changes only when a new filament feeds.
    static func adding(_ filament: String, to list: String?) -> String {
        guard let list, !list.isEmpty else { return filament }
        return list.components(separatedBy: ", ").contains(filament) ? list : "\(list), \(filament)"
    }

    private func openIndex(serial: String, jobId: String? = nil) -> Int? {
        rows.firstIndex { row in
            guard row.serial == serial, row.isOpen else { return false }
            guard let jobId else { return true }
            if jobId.isEmpty || row.jobId.isEmpty { return true }
            return row.jobId == jobId
        }
    }

    private mutating func close(
        serial: String,
        jobId: String,
        outcome: String,
        now: Date,
        live: Bool,
        failCode: String? = nil
    ) {
        guard let i = openIndex(serial: serial, jobId: jobId) else { return }
        rows[i].outcome = outcome
        rows[i].endedAt = live ? now : nil
        rows[i].failCode = failCode
        if !jobId.isEmpty, rows[i].jobId.isEmpty {
            rows[i].jobId = jobId
        }
    }

    private mutating func trim() {
        var i = rows.count - 1
        while rows.count > Self.cap, i >= 0 {
            if !rows[i].isOpen {
                rows.remove(at: i)
            }
            i -= 1
        }
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
