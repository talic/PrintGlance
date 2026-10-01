import Foundation

struct StripPresentation: Equatable, Hashable, Sendable {
    var systemImage: String
    var title: String
    var accessibilityLabel: String
}

struct GlanceContent: Equatable, Sendable {
    var result: FeedResult

    var row: Printer? {
        if case let .doc(doc) = result {
            return doc.focusRow()
        }
        return nil
    }

    static func strip(
        _ result: FeedResult,
        occupancyEndedAt: Date? = nil,
        now: Date = Date()
    ) -> StripPresentation {
        switch result {
        case .feedDown:
            return StripPresentation(
                systemImage: offlineImage,
                title: "",
                accessibilityLabel: "Can't reach printer"
            )
        case .needsSetup:
            return StripPresentation(
                systemImage: "printer",
                title: "",
                accessibilityLabel: "Add your Bambu printer"
            )
        case .connecting:
            return StripPresentation(
                systemImage: "printer",
                title: "",
                accessibilityLabel: "Connecting to printer"
            )
        case let .doc(doc):
            guard let row = doc.focusRow() else {
                return StripPresentation(
                    systemImage: "printer",
                    title: "",
                    accessibilityLabel: "No printer"
                )
            }
            return strip(row: row, occupancyEndedAt: occupancyEndedAt, now: now)
        }
    }

    /// SF Symbols has no `printer.slash`; a missing name draws nothing in the menu bar.
    static let offlineImage = "wifi.slash"
    /// The menu bar drops "40m ago" after this; the checkmark stays.
    static let finishTitleFor: TimeInterval = 2 * 3600

    static func strip(row: Printer, occupancyEndedAt: Date? = nil, now: Date = Date()) -> StripPresentation {
        let st = row.state.uppercased()
        switch st {
        case "PREPARE":
            return StripPresentation(
                systemImage: "printer.fill",
                title: shortStage(row.stage),
                accessibilityLabel: a11y(row)
            )
        case "RUNNING":
            let pct = paddedPercent(row.percent)
            let title: String
            if let eta = row.eta, !eta.isEmpty, let pct {
                title = "\(pct)  \(eta)"
            } else if let pct {
                title = pct
            } else {
                title = ""
            }
            return StripPresentation(
                systemImage: "printer.fill",
                title: title,
                accessibilityLabel: a11y(row)
            )
        case "PAUSE":
            return StripPresentation(
                systemImage: "pause.fill",
                title: paddedPercent(row.percent) ?? "",
                accessibilityLabel: a11y(row)
            )
        case "FINISH":
            let ago = occupancyEndedAt.map { agoTitle(from: $0, now: now) }
            let fresh = occupancyEndedAt.map { now.timeIntervalSince($0) < finishTitleFor } ?? false
            return StripPresentation(
                systemImage: "checkmark",
                title: fresh ? ago ?? "" : "",
                accessibilityLabel: a11y(row, ago: ago)
            )
        case "FAILED":
            return StripPresentation(
                systemImage: "xmark",
                title: "",
                accessibilityLabel: a11y(row)
            )
        case "OFFLINE":
            return StripPresentation(
                systemImage: offlineImage,
                title: "",
                accessibilityLabel: a11y(row)
            )
        default:
            return StripPresentation(
                systemImage: "printer",
                title: "",
                accessibilityLabel: a11y(row)
            )
        }
    }

    /// First word of the stage: "Loading filament" becomes "Loading".
    static func shortStage(_ stage: String?) -> String {
        stage?.split(separator: " ").first.map(String.init) ?? "Starting"
    }

    /// Pads with figure spaces (U+2007), which are as wide as a digit, so the title keeps its width.
    static func paddedPercent(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        let s = "\(percent)%"
        return String(repeating: "\u{2007}", count: max(0, 4 - s.count)) + s
    }

    static func humanState(_ state: String) -> String {
        switch state.uppercased() {
        case "RUNNING": return "Printing"
        case "PREPARE": return "Starting"
        case "PAUSE": return "Paused"
        case "FINISH": return "Finished"
        case "FAILED": return "Failed"
        case "IDLE": return "Idle"
        case "OFFLINE": return "Offline"
        default: return state
        }
    }

    /// The job name while there is a job to talk about; the printer name when idle.
    static func headline(_ row: Printer) -> String {
        if row.state.uppercased() == "IDLE" { return row.name }
        if let job = row.job, !job.isEmpty { return job }
        return row.name
    }

    /// The printer name under a finished or failed job's hero.
    static func caption(_ row: Printer) -> String? {
        guard ["FINISH", "FAILED"].contains(row.state.uppercased()), headline(row) != row.name else {
            return nil
        }
        return row.name
    }

    /// Trays matter when you are at the printer: before a print, after one, or on a paused runout.
    static func showsAMS(_ row: Printer) -> Bool {
        ["IDLE", "FINISH", "FAILED", "PAUSE"].contains(row.state.uppercased())
    }

    static func subtitle(_ row: Printer) -> String {
        if row.state.uppercased() == "PREPARE", let stage = row.stage, !stage.isEmpty {
            return stage
        }
        return humanState(row.state)
    }

    /// Release tags look like `v1.2.0`; the menu shows `Download PrintGlance 1.2.0`.
    static func downloadTitle(tag: String) -> String {
        let version = tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
        return "Download PrintGlance \(version)"
    }

    static func formatRemain(_ seconds: Int) -> String {
        if seconds < 0 { return "--" }
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 {
            return "\(d)d \(h)h"
        }
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return "\(m)m"
    }

    /// "16:25", "16:25 tomorrow", "16:25 yesterday", "16:25 Mon" within 6 days, else "Sep 12".
    /// The hour cycle follows `locale`; day and month words stay English like the rest of the app.
    static func dayTime(
        _ date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if abs(days) > 6 {
            return english(date, DateFormatter.dateFormat(fromTemplate: "MMMd", options: 0, locale: locale), calendar)
        }
        let time = english(date, DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale), calendar)
        switch days {
        case 0: return time
        case 1: return "\(time) tomorrow"
        case -1: return "\(time) yesterday"
        default: return "\(time) \(english(date, "EEE", calendar))"
        }
    }

    /// Formats with the locale's pattern but English words (AM/PM, Mon, Sep).
    private static func english(_ date: Date, _ pattern: String?, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern ?? "HH:mm"
        return f.string(from: date)
    }

    static func isTimed(_ state: String) -> Bool {
        switch state.uppercased() {
        case "RUNNING", "PREPARE", "PAUSE": return true
        default: return false
        }
    }

    static func agoTitle(from ended: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(ended)))
        return "\(formatRemain(s)) ago"
    }

    /// The big line. Nil when it would only repeat the subtitle.
    static func hero(_ row: Printer, occupancyEndedAt: Date? = nil, now: Date = Date()) -> String? {
        switch row.state.uppercased() {
        case "RUNNING", "PREPARE":
            if let eta = row.eta, !eta.isEmpty { return eta }
            return row.remainingS.flatMap { $0 > 0 ? formatRemain($0) : nil }
        case "PAUSE":
            // The finish time slides later while paused; time left holds still.
            return row.remainingS.flatMap { $0 > 0 ? "\(formatRemain($0)) left" : nil }
        case "FINISH":
            return occupancyEndedAt.map { agoTitle(from: $0, now: now) }
        default:
            return nil
        }
    }

    /// "1h 24m left" under a finish-time hero.
    static func remainingLine(_ row: Printer) -> String? {
        guard ["RUNNING", "PREPARE"].contains(row.state.uppercased()),
              let s = row.remainingS, s > 0, let eta = row.eta, !eta.isEmpty
        else {
            return nil
        }
        return "\(formatRemain(s)) left"
    }

    static func layerLine(_ row: Printer) -> String? {
        guard let layer = row.layer else { return nil }
        if let total = row.layerTotal, total > 0 {
            return "Layer \(layer) / \(total)"
        }
        return "Layer \(layer)"
    }

    static func filamentLine(_ row: Printer) -> String? {
        var text: String?
        if let fil = row.filament, !fil.isEmpty {
            if let remain = row.filamentRemain {
                text = "\(fil)  \(remain)%"
            } else {
                text = fil
            }
        }
        if let nozzle = row.nozzle, !nozzle.isEmpty {
            if let text {
                return "\(text) · \(nozzle)"
            }
            return nozzle
        }
        return text
    }

    private static func a11y(_ row: Printer, ago: String? = nil) -> String {
        let st = row.state.uppercased()
        let timed = isTimed(st)
        var parts = [row.name, [humanState(st).lowercased(), ago].compactMap { $0 }.joined(separator: " ")]
        if let p = row.percent, timed || st == "FAILED" {
            parts.append("\(p) percent")
        }
        if st == "RUNNING" || st == "PREPARE", let eta = row.eta, !eta.isEmpty {
            parts.append("finish \(eta)")
        }
        if timed, let layer = layerLine(row) {
            parts.append(layer.lowercased())
        }
        if timed, let nozzle = row.nozzle, !nozzle.isEmpty {
            parts.append("\(nozzle.lowercased()) nozzle")
        }
        return parts.joined(separator: ", ")
    }
}

enum GlanceCopy {
    static func feedDownDetail(reason: String?) -> String {
        let r = reason ?? ""
        if r.contains("ECONNREFUSED") {
            return "The printer is on the Wi-Fi, but it isn't accepting a local connection. On the printer, open Settings, then LAN or Network, and turn on LAN mode."
        }
        if r.contains("MQTT CONNACK") {
            return "The access code was rejected. Check the access code on the printer's LAN or Network page."
        }
        return "Can't reach the printer. Check Wi-Fi and the IP address."
    }
}
