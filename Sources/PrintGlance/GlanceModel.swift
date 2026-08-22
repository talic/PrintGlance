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
        case .needsSetup:
            return "Add printer"
        case .connecting:
            return "Connecting"
        case .doc:
            guard let row else { return "No printer" }
            return "\(row.name) · \(Self.humanState(row.state))"
        }
    }

    var pollInterval: TimeInterval {
        switch result {
        case .feedDown, .unauthorized, .http, .invalid, .connecting:
            return 15
        case .needsSetup:
            return 60
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
    @Published private(set) var content = GlanceContent(result: .needsSetup)
    @Published private(set) var availableUpdate: String?
    @Published var settings = PrinterSettings.load()

    private let mqtt = MQTT311Client()
    private let updates = AppUpdateChecker()
    private var snapshot: BambuSnapshot?
    private var staleTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?

    private func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PrintGlance.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    var strip: StripPresentation { content.strip }

    func start() {
        mqtt.onConnect = { [weak self] in self?.didConnect() }
        mqtt.onDisconnect = { [weak self] reason in self?.didDisconnect(reason) }
        mqtt.onMessage = { [weak self] _, data in self?.didMessage(data) }
        updates.onAvailable = { [weak self] tag in
            guard let self, self.availableUpdate != tag else { return }
            self.availableUpdate = tag
        }
        updates.start()
        applySettingsAndConnect()
        staleTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.publishSnapshot()
            }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applySettingsAndConnect()
                await self?.updates.checkIfDue()
            }
        }
    }

    func openUpdatePage() {
        NSWorkspace.shared.open(AppUpdate.latestReleaseURL)
    }

    func saveSettings(_ next: PrinterSettings) {
        next.save()
        settings = next
        applySettingsAndConnect()
    }

    private func applySettingsAndConnect() {
        mqtt.disconnect()
        snapshot = nil
        guard settings.isComplete else {
            apply(GlanceContent(result: .needsSetup))
            return
        }
        apply(GlanceContent(result: .connecting))
        let id = settings.serial
        let name = settings.name.isEmpty ? "Printer" : settings.name
        snapshot = BambuSnapshot(printerID: id, name: name)
        let suffix = settings.serial.suffix(6)
        log("connecting \(settings.ip):8883")
        mqtt.connect(
            host: settings.ip,
            port: 8883,
            clientID: "printglance-\(suffix)",
            username: "bblp",
            password: settings.accessCode
        )
        connectTimeout?.cancel()
        connectTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .connecting = self.content.result {
                self.log("connect timed out")
                self.apply(GlanceContent(result: .feedDown))
            }
        }
    }

    private func didConnect() {
        connectTimeout?.cancel()
        log("connected")
        NSLog("PrintGlance: connected to printer")
        mqtt.subscribe("device/\(settings.serial)/report")
        let body = Data(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8)
        mqtt.publish(topic: "device/\(settings.serial)/request", payload: body)
        snapshot?.markConnected(true)
    }

    private func didDisconnect(_ reason: String?) {
        log("disconnected \(reason ?? "")")
        NSLog("PrintGlance: printer connection dropped")
        snapshot?.markConnected(false)
        if settings.isComplete {
            apply(GlanceContent(result: .feedDown))
        } else {
            apply(GlanceContent(result: .needsSetup))
        }
    }

    private func didMessage(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        snapshot?.ingest(obj)
        publishSnapshot()
    }

    private func publishSnapshot() {
        guard settings.isComplete, let snapshot, snapshot.hasReport else { return }
        apply(GlanceContent(result: .doc(snapshot.doc())))
    }

    private func apply(_ next: GlanceContent) {
        if content != next {
            content = next
        }
    }
}
