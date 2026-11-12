import Foundation

/// The printers as PrintGlance sees them, written to `printers.json` beside the history so another app on
/// this Mac can read them (Model Browser plans its print queue from it). PrintGlance never reads it back.
/// Version 1. Add fields only as optionals: readers skip what they don't know.
struct PrinterFile: Codable, Equatable, Sendable {
    static let fileName = "printers.json"

    var v = 1
    var printers: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        /// The printer's serial.
        var id: String
        var name: String
        /// The card's word: Starting, Printing, Paused, Finished, Failed, Idle or Offline.
        var state: String
        /// The printer's `gcode_state` as PrintGlance reads it: PREPARE, RUNNING, PAUSE, FINISH, FAILED, IDLE or OFFLINE.
        var code: String
        /// Starting only: Heating, Leveling, and so on.
        var stage: String?
        /// What the slicer called the print (`subtask_name`), as sent: usually the project's name.
        var project: String?
        /// The plate it came from, when the printer names the file (`Metadata/plate_3.gcode`).
        var plate: Int?
        /// The label the card shows.
        var job: String?
        var jobId: String?
        var percent: Int?
        var remainingS: Int?
        /// Starting, Printing or Paused: when the printer should report Finished, with how late it runs added.
        var finishAt: Date?
        /// When PrintGlance saw this print start, if it did.
        var startedAt: Date?
        /// Finished or Failed: when PrintGlance saw it end, if it did.
        var endedAt: Date?
        /// Paused or Failed: why, in words, when a code has a plain reason.
        var reason: String?
        /// Paused or Failed: the codes the printer gave.
        var errorCodes: [String]?
        /// Offline only: when the last report arrived.
        var lastSeen: Date?
        var trays: [Tray]?
    }

    struct Tray: Codable, Equatable, Sendable {
        /// A1…D4, HT-A, External.
        var slot: String?
        /// "PLA Matte".
        var filament: String?
        /// RRGGBBAA.
        var color: String?
        /// Percent left, when the spool reports it.
        var remain: Int?
    }

    /// The file beside `jobs.json`, so tests that give the model a scratch history get a scratch file too.
    static func url(besideHistory history: URL) -> URL {
        history.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// One entry per printer, from the rows the card shows and each printer's raw report.
    static func make(doc: PrintDoc, reports: [String: [String: Any]], history: [JobLogRow], now: Date = Date()) -> PrinterFile {
        PrinterFile(printers: doc.printers.map { row in
            let report = reports[row.id] ?? [:]
            let state = row.state.uppercased()
            let timed = ["PREPARE", "RUNNING", "PAUSE"].contains(state)
            let codes = GlanceContent.errorCodes(row)
            // The newest history row for this print.
            let logged = history.first { $0.serial == row.id && row.jobId != nil && $0.jobId == row.jobId }
            return Entry(
                id: row.id,
                name: row.name,
                state: GlanceContent.humanState(row.state),
                code: state,
                stage: row.stage,
                project: projectName(report),
                plate: plateNumber(report["gcode_file"]),
                job: row.job,
                jobId: row.jobId,
                percent: row.percent,
                remainingS: row.remainingS,
                finishAt: timed ? row.remainingS.map { minute(now.addingTimeInterval(TimeInterval($0))) } : nil,
                startedAt: logged?.startAt,
                endedAt: ["FINISH", "FAILED"].contains(state) ? logged?.endedAt : nil,
                reason: GlanceContent.errorReason(row),
                errorCodes: codes.isEmpty ? nil : codes,
                lastSeen: row.lastSeen,
                trays: row.trays.map { $0.map { Tray(slot: $0.label, filament: $0.name, color: $0.color, remain: $0.remain) } }
            )
        })
    }

    /// `subtask_name` as sent, trimmed. Nil when empty.
    static func projectName(_ report: [String: Any]) -> String? {
        guard let s = BambuJSON.stringValue(report["subtask_name"])?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty else { return nil }
        return s
    }

    /// 3 for `/data/Metadata/plate_3.gcode`. Nil for any other file name.
    static func plateNumber(_ gcodeFile: Any?) -> Int? {
        guard let s = BambuJSON.stringValue(gcodeFile),
              let match = s.range(of: #"plate_(\d+)\.gcode$"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return Int(s[match].dropFirst("plate_".count).dropLast(".gcode".count))
    }

    /// Whole minutes, so the time doesn't move with the second each report arrives in.
    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
