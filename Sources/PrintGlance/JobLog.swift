import Foundation

struct JobLogRow: Codable, Equatable, Sendable, Identifiable {
    var serial: String
    var name: String
    var jobId: String
    var job: String?
    var filament: String?
    var startAt: Date
    var endedAt: Date?
    var outcome: String?

    var id: String {
        "\(serial)|\(jobId)|\(startAt.timeIntervalSince1970)"
    }

    var isOpen: Bool { outcome == nil }
}

struct JobLog {
    static let cap = 50
    static let outcomeOK = "ok"
    static let outcomeFail = "fail"

    var rows: [JobLogRow] = []
    /// Process-local. Not written to disk.
    var lastState: [String: String] = [:]
    var hadTimed: [String: Bool] = [:]

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
        struct Envelope: Codable { var rows: [JobLogRow] }
        guard let env = try? dec.decode(Envelope.self, from: data) else { return JobLog() }
        return JobLog(rows: env.rows)
    }

    func save(to url: URL) {
        struct Envelope: Codable { var rows: [JobLogRow] }
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

    func recent(_ n: Int) -> [JobLogRow] {
        Array(rows.prefix(n))
    }

    func occupancyEndedAt(serial: String, state: String, jobId: String?) -> Date? {
        guard state.uppercased() == "FINISH" else { return nil }
        let id = jobId ?? ""
        return rows.first { row in
            row.serial == serial
                && row.outcome == Self.outcomeOK
                && (id.isEmpty || row.jobId.isEmpty || row.jobId == id)
        }?.endedAt
    }

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines = ["started,ended,duration_min,printer,job,filament,outcome"]
        for row in rows {
            let started = iso.string(from: row.startAt)
            let ended = row.endedAt.map { iso.string(from: $0) } ?? ""
            let duration: String
            if let end = row.endedAt {
                duration = "\(max(0, Int(end.timeIntervalSince(row.startAt) / 60)))"
            } else {
                duration = ""
            }
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
        let next = printer.state.uppercased()
        let jobId = printer.jobId ?? ""
        switch next {
        case "RUNNING", "PREPARE":
            hadTimed[printer.id] = true
            if let i = openIndex(serial: printer.id),
               !rows[i].jobId.isEmpty, !jobId.isEmpty, rows[i].jobId != jobId
            {
                rows[i].outcome = Self.outcomeOK
            }
            openOrUpdate(printer, jobId: jobId, now: now)
        case "FINISH":
            close(
                serial: printer.id,
                jobId: jobId,
                outcome: Self.outcomeOK,
                now: now,
                live: hadTimed[printer.id] == true
            )
            hadTimed[printer.id] = false
        case "FAILED":
            close(
                serial: printer.id,
                jobId: jobId,
                outcome: Self.outcomeFail,
                now: now,
                live: hadTimed[printer.id] == true
            )
            hadTimed[printer.id] = false
        case "IDLE":
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
        lastState[printer.id] = next
    }

    private mutating func openOrUpdate(_ printer: Printer, jobId: String, now: Date) {
        if let i = openIndex(serial: printer.id, jobId: jobId) {
            if rows[i].jobId.isEmpty, !jobId.isEmpty {
                rows[i].jobId = jobId
            }
            if let job = printer.job, !job.isEmpty { rows[i].job = job }
            if let fil = printer.filament, !fil.isEmpty { rows[i].filament = fil }
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
                outcome: nil
            ),
            at: 0
        )
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
        live: Bool
    ) {
        guard let i = openIndex(serial: serial, jobId: jobId) else { return }
        rows[i].outcome = outcome
        rows[i].endedAt = live ? now : nil
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
