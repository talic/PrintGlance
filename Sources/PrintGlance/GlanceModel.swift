import AppKit
import Combine
import Foundation
import UserNotifications

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
        if let nozzle = row.nozzle, !nozzle.isEmpty {
            parts.append("\(nozzle.lowercased()) nozzle")
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
final class GlanceModel: ObservableObject {
    @Published private(set) var content = GlanceContent(result: .needsSetup)
    @Published private(set) var availableUpdate: String?
    @Published var settings = SavedPrinters.load()
    @Published var notifyPrefs: PrintNotifyPrefs {
        didSet {
            notify.prefs = notifyPrefs
            notifyPrefs.save(.standard)
        }
    }

    private final class Link {
        let mqtt = MQTT311Client()
        let snapshot: BambuSnapshot
        var timeout: Task<Void, Never>?
        var failed = false

        init(printer: PrinterSettings) {
            snapshot = BambuSnapshot(printerID: printer.serial, name: printer.displayName)
        }

        func tearDown() {
            timeout?.cancel()
            timeout = nil
            mqtt.onConnect = nil
            mqtt.onDisconnect = nil
            mqtt.onMessage = nil
            mqtt.disconnect()
        }
    }

    private var links: [String: Link] = [:]
    private let updates = AppUpdateChecker()
    private var filament = FilamentAlert()
    private var staleTask: Task<Void, Never>?
    private var notify: PrintNotify
    private let notifyPresenter = PrintNotifyPresenter()

    init() {
        let settings = SavedPrinters.load()
        let prefs = PrintNotifyPrefs.load(.standard)
        self.settings = settings
        self.notifyPrefs = prefs
        self.notify = PrintNotify(
            serial: settings.focusId ?? settings.printers.first?.serial ?? "",
            prefs: prefs,
            stamp: PrintNotifyStamp.load(.standard)
        )
    }

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
        UNUserNotificationCenter.current().delegate = notifyPresenter
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

    func addPrinter(_ printer: PrinterSettings) {
        saveSettings(settings.adding(printer))
    }

    func updatePrinter(_ printer: PrinterSettings, serial: String) {
        saveSettings(settings.replacing(printer, serial: serial))
    }

    func removePrinter(serial: String) {
        saveSettings(settings.removing(serial: serial))
    }

    func focusPrinter(_ id: String) {
        let next = settings.focusing(id)
        next.save()
        settings = next
        notify.serial = id
        publishSnapshot()
    }

    func saveSettings(_ next: SavedPrinters) {
        next.save()
        settings = next
        notify.serial = next.focusId ?? next.printers.first?.serial ?? ""
        applySettingsAndConnect()
    }

    private func applySettingsAndConnect() {
        for link in links.values {
            link.tearDown()
        }
        links.removeAll()
        let complete = settings.printers.filter(\.isComplete)
        guard !complete.isEmpty else {
            apply(GlanceContent(result: .needsSetup))
            return
        }
        apply(GlanceContent(result: .connecting))
        for printer in complete {
            let id = printer.serial
            let link = Link(printer: printer)
            link.mqtt.onConnect = { [weak self] in self?.didConnect(id) }
            link.mqtt.onDisconnect = { [weak self] reason in self?.didDisconnect(id, reason) }
            link.mqtt.onMessage = { [weak self] _, data in self?.didMessage(id, data) }
            links[id] = link
            log("connecting \(printer.ip):8883")
            link.mqtt.connect(
                host: printer.ip,
                port: 8883,
                clientID: "printglance-\(id.suffix(6))",
                username: "bblp",
                password: printer.accessCode
            )
            link.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let link = self.links[id], !link.snapshot.hasReport else { return }
                link.failed = true
                self.log("connect timed out \(id)")
                self.publishSnapshot()
            }
        }
    }

    private func didConnect(_ id: String) {
        guard let link = links[id] else { return }
        link.timeout?.cancel()
        link.failed = false
        log("connected \(id)")
        NSLog("PrintGlance: connected to printer")
        link.mqtt.subscribe("device/\(id)/report")
        let body = Data(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8)
        link.mqtt.publish(topic: "device/\(id)/request", payload: body)
        link.snapshot.markConnected(true)
    }

    private func didDisconnect(_ id: String, _ reason: String?) {
        guard let link = links[id] else { return }
        log("disconnected \(id) \(reason ?? "")")
        NSLog("PrintGlance: printer connection dropped")
        link.snapshot.markConnected(false)
        link.failed = true
        publishSnapshot()
    }

    private func didMessage(_ id: String, _ data: Data) {
        guard let link = links[id] else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        link.snapshot.ingest(obj)
        publishSnapshot()
    }

    private func publishSnapshot() {
        let complete = settings.printers.filter(\.isComplete)
        guard !complete.isEmpty else {
            apply(GlanceContent(result: .needsSetup))
            return
        }
        let snaps = Dictionary(uniqueKeysWithValues: links.map { ($0.key, $0.value.snapshot) })
        if snaps.values.contains(where: { $0.hasReport }) {
            let doc = BambuSnapshot.fleetDoc(
                printers: complete,
                snapshots: snaps,
                focusId: settings.focusId
            )
            apply(GlanceContent(result: .doc(doc)))
            if let row = doc.focusRow(), let snap = snaps[row.id] {
                let fil = BambuPrint.activeFilament(snap.printObj)
                if let notice = filament.consider(
                    serial: row.id,
                    name: row.name,
                    state: row.state,
                    filament: fil.type,
                    tray: fil.tray,
                    remain: fil.remain,
                    taskId: BambuPrint.taskId(snap.printObj)
                ) {
                    deliverFilament(notice)
                }
            }
            return
        }
        if links.values.contains(where: { !$0.failed }) {
            apply(GlanceContent(result: .connecting))
        } else {
            apply(GlanceContent(result: .feedDown))
        }
    }

    private func deliverFilament(_ notice: FilamentAlert.Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: notice.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func apply(_ next: GlanceContent) {
        if content != next {
            let outcome = notify.observe(next)
            notify.persistStamp(.standard)
            deliver(outcome)
            content = next
        }
    }

    private func deliver(_ outcome: PrintNotifyOutcome) {
        if outcome.requestPermission {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        guard let alert = outcome.alert else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let id = notify.serial.isEmpty ? "printer" : notify.serial
        let request = UNNotificationRequest(
            identifier: "pg.\(alert.kind.rawValue).\(id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Menu bar extras stay running, so banners must be presented while the extra is active.
private final class PrintNotifyPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
