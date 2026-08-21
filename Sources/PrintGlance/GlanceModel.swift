import AppKit
import Combine
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

    var strip: StripPresentation {
        Self.strip(result)
    }

    var footer: String {
        switch result {
        case .feedDown:
            return "Feed off"
        case .unauthorized:
            return "Token required"
        case let .http(code):
            return "HTTP \(code)"
        case .invalid:
            return "Bad feed"
        case .doc:
            guard let row else { return "No printer" }
            return "\(row.name) · \(Self.humanState(row.state))"
        }
    }

    var pollInterval: TimeInterval {
        switch result {
        case .feedDown, .unauthorized, .http, .invalid:
            return 15
        case .doc:
            guard let row else { return 15 }
            switch row.state.uppercased() {
            case "RUNNING", "PREPARE", "PAUSE":
                return 5
            case "FINISH", "FAILED":
                return 30
            default:
                return 60
            }
        }
    }

    static func strip(_ result: FeedResult) -> StripPresentation {
        switch result {
        case .feedDown:
            return StripPresentation(
                systemImage: "printer.slash",
                title: "",
                accessibilityLabel: "Print feed off"
            )
        case .unauthorized:
            return StripPresentation(
                systemImage: "printer.slash",
                title: "",
                accessibilityLabel: "Print feed token required"
            )
        case .http:
            return StripPresentation(
                systemImage: "printer.slash",
                title: "",
                accessibilityLabel: "Print feed error"
            )
        case .invalid:
            return StripPresentation(
                systemImage: "printer.slash",
                title: "",
                accessibilityLabel: "Print feed unreadable"
            )
        case let .doc(doc):
            guard let row = doc.focusRow() else {
                return StripPresentation(
                    systemImage: "printer.slash",
                    title: "",
                    accessibilityLabel: "No printer"
                )
            }
            return strip(row: row)
        }
    }

    static func strip(row: Printer) -> StripPresentation {
        let st = row.state.uppercased()
        switch st {
        case "RUNNING", "PREPARE":
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
            return StripPresentation(
                systemImage: "checkmark",
                title: "",
                accessibilityLabel: a11y(row)
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
        case "FINISH": return "Done"
        case "FAILED": return "Failed"
        case "IDLE": return "Idle"
        case "OFFLINE": return "Offline"
        default: return state
        }
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

    static func hero(_ row: Printer) -> String {
        let timed = isTimed(row.state)
        if timed, let eta = row.eta, !eta.isEmpty {
            return eta
        }
        if timed, let s = row.remainingS, s > 0 {
            return formatRemain(s)
        }
        switch row.state.uppercased() {
        case "FINISH": return "Done"
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
        guard let fil = row.filament, !fil.isEmpty else { return nil }
        if let remain = row.filamentRemain {
            return "\(fil)  \(remain)%"
        }
        return fil
    }

    private static func a11y(_ row: Printer) -> String {
        var parts = [row.name, humanState(row.state).lowercased()]
        if let p = row.percent {
            parts.append("\(p) percent")
        }
        if isTimed(row.state), let eta = row.eta, !eta.isEmpty {
            parts.append("finish \(eta)")
        }
        if let layer = layerLine(row) {
            parts.append(layer.lowercased())
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
final class GlanceModel: ObservableObject {
    @Published private(set) var content = GlanceContent(result: .feedDown)

    private let feed: PrintFeed
    private var loopTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var lastBody: Data?

    var strip: StripPresentation { content.strip }

    init(feed: PrintFeed = PrintFeed()) {
        self.feed = feed
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let ns = UInt64(self.content.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        wakeTask = Task { @MainActor [weak self] in
            let notes = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            )
            for await _ in notes {
                guard let self, !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard let (code, data) = await feed.fetchRaw() else {
            lastBody = nil
            apply(GlanceContent(result: .feedDown))
            return
        }
        if data == lastBody { return }
        lastBody = data
        apply(GlanceContent(result: PrintFeed.interpret(status: code, data: data)))
    }

    private func apply(_ next: GlanceContent) {
        if content != next {
            content = next
        }
    }
}
