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
                systemImage: "printer.slash",
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
                    systemImage: "printer.slash",
                    title: "",
                    accessibilityLabel: "No printer"
                )
            }
            return strip(row: row, occupancyEndedAt: occupancyEndedAt, now: now)
        }
    }

    static func strip(row: Printer, occupancyEndedAt: Date? = nil, now: Date = Date()) -> StripPresentation {
        let st = row.state.uppercased()
        switch st {
        case "PREPARE":
            let title = row.stage ?? "Starting"
            return StripPresentation(
                systemImage: "printer.fill",
                title: title,
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
            let title = occupancyEndedAt.map { agoTitle(from: $0, now: now) } ?? ""
            return StripPresentation(
                systemImage: "checkmark",
                title: title,
                accessibilityLabel: a11y(row, occupancyTitle: title)
            )
        case "FAILED":
            return StripPresentation(
                systemImage: "xmark",
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

    static func paddedPercent(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        return String(format: "%3d%%", percent)
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

    static func headline(_ row: Printer) -> String {
        if let job = row.job, !job.isEmpty { return job }
        return row.name
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
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return "\(m)m"
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

    static func hero(_ row: Printer, occupancyEndedAt: Date? = nil, now: Date = Date()) -> String {
        let timed = isTimed(row.state)
        if timed, let eta = row.eta, !eta.isEmpty {
            return eta
        }
        if timed, let s = row.remainingS, s > 0 {
            return formatRemain(s)
        }
        switch row.state.uppercased() {
        case "FINISH":
            if let occupancyEndedAt {
                return agoTitle(from: occupancyEndedAt, now: now)
            }
            return "Finished"
        case "FAILED": return "Failed"
        case "IDLE": return "Idle"
        case "OFFLINE": return "Offline"
        default: return humanState(row.state)
        }
    }

    static func remainingLine(_ row: Printer) -> String? {
        guard isTimed(row.state), let s = row.remainingS, s > 0, let eta = row.eta, !eta.isEmpty else {
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

    private static func a11y(_ row: Printer, occupancyTitle: String = "") -> String {
        var parts = [row.name, humanState(row.state).lowercased()]
        if !occupancyTitle.isEmpty {
            parts.append(occupancyTitle)
        }
        if let p = row.percent {
            parts.append("\(p) percent")
        }
        if isTimed(row.state), let eta = row.eta, !eta.isEmpty {
            parts.append("finish \(eta)")
        }
        if let layer = layerLine(row) {
            parts.append(layer.lowercased())
        }
        if let nozzle = row.nozzle, !nozzle.isEmpty {
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
