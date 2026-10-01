import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class GlanceModel: ObservableObject {
    @Published private(set) var content = GlanceContent(result: .needsSetup)
    /// Last disconnect reason per printer serial. A successful connect clears that printer's entry.
    @Published private(set) var disconnectReasons: [String: String] = [:]
    @Published private(set) var availableUpdate: String?
    @Published var settings: SavedPrinters
    @Published var notifyPrefs: PrintNotifyPrefs {
        didSet {
            notify.prefs = notifyPrefs
            notifyPrefs.save(.standard)
        }
    }
    @Published private(set) var occupancyNow = Date()
    @Published private(set) var historyRows: [JobLogRow] = []

    private final class Link {
        let mqtt = MQTT311Client()
        let snapshot: BambuSnapshot
        var printer: PrinterSettings
        var timeout: Task<Void, Never>?
        var failed = false
        /// CONNACK for this attempt. A prior session can still have `hasReport`.
        var handshake = false
        var reconnectAttempt = 0
        /// CONNACK time of the current session, nil when not connected.
        var connectedAt: Date?
        /// Dial this address. Preferences keep the saved IP until connect succeeds.
        var candidateIP: String?
        /// The saved IP answered and rejected the access code.
        var authRejected = false

        init(printer: PrinterSettings) {
            self.printer = printer
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
    private var adoptScan: Task<Void, Never>?
    private var adoptGeneration: UInt64 = 0
    private var lastAdoptScanAt: Date?
    private var waitingOnScan: Set<String> = []
    private var rediscoverPausedSerial: String?
    private static let adoptGap: TimeInterval = 60
    private static let instanceTag = String(UInt16.random(in: .min ... .max), radix: 16)
    private let updates = AppUpdateChecker()
    private var filament = FilamentAlert()
    private var staleTask: Task<Void, Never>?
    private var notify: PrintNotify
    private let notifyPresenter = PrintNotifyPresenter()
    private var jobLog: JobLog
    private let jobLogURL: URL
    private var occupancyTask: Task<Void, Never>?
    private var comingOff = ComingOff()

    init(jobLogURL: URL = JobLog.fileURL()) {
        let settings = SavedPrinters.load()
        let prefs = PrintNotifyPrefs.load(.standard)
        self.settings = settings
        self.notifyPrefs = prefs
        self.notify = PrintNotify(
            serial: settings.focusId ?? settings.printers.first?.serial ?? "",
            prefs: prefs,
            stamps: PrintNotifyStamp.loadAll(.standard)
        )
        self.jobLogURL = jobLogURL
        let log = JobLog.load(from: jobLogURL)
        self.jobLog = log
        self.historyRows = log.recent(20)
        self.comingOff = ComingOff.load(.standard)
    }

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PrintGlance.log")

    private func log(_ msg: String) {
        let line = "\(Date().ISO8601Format()) \(msg)\n"
        let url = Self.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    var strip: StripPresentation {
        GlanceContent.strip(
            content.result,
            occupancyEndedAt: occupancyEndedAt,
            now: occupancyNow
        )
    }

    var occupancyEndedAt: Date? {
        content.row.flatMap(occupancyEndedAt(for:))
    }

    func occupancyEndedAt(for row: Printer) -> Date? {
        jobLog.occupancyEndedAt(serial: row.id, state: row.state, jobId: row.jobId)
    }

    func exportHistory(to url: URL) {
        try? jobLog.csv().write(to: url, atomically: true, encoding: .utf8)
    }

    func start() {
        // ponytail: crude 1 MB cap, wipes all history; rotate instead if old lines ever matter.
        if let size = try? Self.logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? FileManager.default.removeItem(at: Self.logURL)
        }
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
                self?.reconnectAfterWake()
                await self?.updates.checkIfDue()
            }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Inline, not a Task: the freeze must land before the Mac sleeps.
            MainActor.assumeIsolated {
                self?.links.values.forEach { $0.snapshot.willSleep() }
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
        publishSnapshot()
    }

    func setRediscoverPausedSerial(_ serial: String?) {
        rediscoverPausedSerial = serial
    }

    func saveSettings(_ next: SavedPrinters) {
        next.save()
        settings = next
        applySettingsAndConnect()
    }

    private func applySettingsAndConnect() {
        cancelAdoptScan()
        for link in links.values {
            link.tearDown()
        }
        links.removeAll()
        if !disconnectReasons.isEmpty { disconnectReasons = [:] }
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
            beginConnect(id)
        }
    }

    private func reconnectAfterWake() {
        links.values.forEach { $0.snapshot.didWake() }
        if links.isEmpty {
            applySettingsAndConnect()
            return
        }
        for id in links.keys {
            guard let link = links[id] else { continue }
            link.reconnectAttempt = 0
            if link.failed, !link.authRejected {
                requestRediscover(id) { self.beginConnect(id) }
            } else {
                beginConnect(id)
            }
        }
    }

    private func beginConnect(_ id: String) {
        guard let link = links[id] else { return }
        link.timeout?.cancel()
        link.handshake = false
        link.connectedAt = nil
        // Keep `failed` through retries. Clearing it publishes `.connecting`,
        // remounts the extra as `printer` on Tahoe, and the icon flashes off.
        let printer = link.printer
        log("connecting \(printer.ip):8883")
        link.mqtt.connect(
            host: printer.ip,
            port: 8883,
            clientID: "pg-app-\(id.suffix(6))-\(Self.instanceTag)",
            username: "bblp",
            password: printer.accessCode
        )
        link.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let link = self.links[id], !link.handshake else { return }
            link.failed = true
            link.authRejected = false
            link.snapshot.connectionLost()
            self.noteDisconnect(id, "connect timed out")
            self.log("connect timed out \(id)")
            link.mqtt.disconnect()
            self.publishSnapshot()
            self.revertCandidate(id)
            self.requestRediscover(id) { self.scheduleReconnect(id) }
        }
    }

    private func scheduleReconnect(_ id: String) {
        guard let link = links[id] else { return }
        link.timeout?.cancel()
        link.reconnectAttempt += 1
        let attempt = link.reconnectAttempt
        let ns = MQTT311Client.reconnectDelayNanoseconds(attempt: attempt)
        log("reconnect \(id) in \(MQTT311Client.reconnectDelaySeconds(attempt: attempt))s")
        link.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            self.beginConnect(id)
        }
    }

    private func isAccessRejected(_ reason: String?) -> Bool {
        reason?.hasPrefix("MQTT CONNACK") == true
    }

    private func requestRediscover(_ id: String, ifSkipped: () -> Void) {
        guard links[id] != nil else { return }
        if adoptScan != nil {
            waitingOnScan.insert(id)
            return
        }
        if let lastAdoptScanAt, Date().timeIntervalSince(lastAdoptScanAt) < Self.adoptGap {
            ifSkipped()
            return
        }
        waitingOnScan.insert(id)
        startAdoptScan()
    }

    private func startAdoptScan() {
        adoptGeneration &+= 1
        let generation = adoptGeneration
        lastAdoptScanAt = Date()
        adoptScan = Task { @MainActor [weak self] in
            let hits = await PrinterDiscovery.scan()
            guard let self, !Task.isCancelled, generation == self.adoptGeneration else { return }
            self.adoptScan = nil
            self.finishAdoptScan(hits: hits)
        }
    }

    private func finishAdoptScan(hits: [PrinterDiscovery.Hit]) {
        let waiting = waitingOnScan
        waitingOnScan = []
        let pairs = PrinterDiscovery.ipChanges(saved: settings.printers, hits: hits)
        var adopted = Set<String>()
        for (serial, ip) in pairs {
            guard let link = links[serial], link.failed, !link.authRejected, link.candidateIP == nil else {
                continue
            }
            if formBlocksRediscover(serial) { continue }
            link.candidateIP = ip
            var printer = link.printer
            printer.ip = ip
            link.printer = printer
            link.reconnectAttempt = 0
            beginConnect(serial)
            adopted.insert(serial)
        }
        for id in waiting where !adopted.contains(id) {
            guard links[id] != nil else { continue }
            scheduleReconnect(id)
        }
    }

    private func cancelAdoptScan() {
        adoptGeneration &+= 1
        adoptScan?.cancel()
        adoptScan = nil
        waitingOnScan = []
    }

    private func formBlocksRediscover(_ serial: String) -> Bool {
        guard let paused = rediscoverPausedSerial?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !paused.isEmpty
        else { return false }
        return paused.caseInsensitiveCompare(
            serial.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }

    private func savedPrinter(serial: String) -> PrinterSettings? {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings.printers.first {
            $0.serial.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(key) == .orderedSame
        }
    }

    private func revertCandidate(_ id: String) {
        guard let link = links[id], link.candidateIP != nil else { return }
        link.candidateIP = nil
        if let saved = savedPrinter(serial: id) {
            link.printer = saved
        }
    }

    private func commitCandidate(_ id: String) {
        guard let link = links[id], let candidate = link.candidateIP else { return }
        link.candidateIP = nil
        guard let old = savedPrinter(serial: id)?.ip,
              let next = settings.changingIP(serial: id, to: candidate)
        else { return }
        next.save()
        settings = next
        log("ip \(id) \(old) -> \(candidate)")
    }

    private func didConnect(_ id: String) {
        guard let link = links[id] else { return }
        link.timeout?.cancel()
        link.failed = false
        link.handshake = true
        link.connectedAt = Date()
        link.authRejected = false
        commitCandidate(id)
        noteDisconnect(id, nil)
        log("connected \(id)")
        link.mqtt.subscribe("device/\(id)/report")
        let body = Data(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8)
        link.mqtt.publish(topic: "device/\(id)/request", payload: body)
        publishSnapshot()
    }

    private func didDisconnect(_ id: String, _ reason: String?) {
        guard let link = links[id] else { return }
        noteDisconnect(id, reason)
        log("disconnected \(id) \(reason ?? "")")
        link.handshake = false
        link.snapshot.connectionLost()
        link.failed = true
        // Reset backoff only after a stable session, so accept-then-drop keeps backing off.
        if let at = link.connectedAt, Date().timeIntervalSince(at) >= 30 {
            link.reconnectAttempt = 0
        }
        link.connectedAt = nil
        publishSnapshot()
        if isAccessRejected(reason) {
            link.authRejected = true
            revertCandidate(id)
            scheduleReconnect(id)
        } else {
            link.authRejected = false
            revertCandidate(id)
            requestRediscover(id) { self.scheduleReconnect(id) }
        }
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
            let rowsBefore = jobLog.rows
            jobLog.observe(printers: doc.printers)
            if jobLog.rows != rowsBefore {
                jobLog.save(to: jobLogURL)
                historyRows = jobLog.recent(20)
            }
            let comingOffBefore = comingOff
            for row in doc.printers {
                if let action = comingOff.consider(printer: row, prefs: notifyPrefs) {
                    deliverComingOff(action)
                }
            }
            if comingOff != comingOffBefore {
                comingOff.save(.standard)
            }
            apply(GlanceContent(result: .doc(doc)))
            syncOccupancyClock()
            for row in doc.printers {
                guard let snap = snaps[row.id] else { continue }
                let fil = BambuPrint.activeFilament(snap.printObj)
                if let notice = filament.consider(
                    serial: row.id,
                    name: row.name,
                    state: row.state,
                    filament: fil.type,
                    tray: fil.tray,
                    remain: fil.remain,
                    taskId: BambuPrint.jobIdentity(snap.printObj)
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
        post(id: notice.identifier, title: notice.title, body: notice.body)
    }

    private func post(id: String, title: String, body: String, trigger: UNNotificationTrigger? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }

    private func noteDisconnect(_ id: String, _ reason: String?) {
        if disconnectReasons[id] != reason {
            disconnectReasons[id] = reason
        }
    }

    /// That printer's reason, else any printer's.
    func disconnectReason(for id: String?) -> String? {
        id.flatMap { disconnectReasons[$0] } ?? disconnectReasons.values.first
    }

    private func apply(_ next: GlanceContent) {
        if content != next {
            let stampsBefore = notify.stamps
            let outcome = notify.observe(next)
            if notify.stamps != stampsBefore {
                notify.persistStamp(.standard)
            }
            deliver(outcome)
            content = next
        }
        if case .doc = next.result {
            return
        }
        occupancyTask?.cancel()
        occupancyTask = nil
    }

    /// The minute clock runs while any printer shows elapsed time or an offline printer's last update.
    private var clockNeeded: Bool {
        guard case let .doc(doc) = content.result else { return false }
        return doc.printers.contains { $0.lastSeen != nil || occupancyEndedAt(for: $0) != nil }
    }

    private func syncOccupancyClock() {
        guard clockNeeded else {
            occupancyTask?.cancel()
            occupancyTask = nil
            return
        }
        guard occupancyTask == nil else { return }
        occupancyNow = Date()
        occupancyTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.clockNeeded else {
                    self.occupancyTask = nil
                    return
                }
                self.occupancyNow = Date()
            }
        }
    }

    private func deliver(_ outcome: PrintNotifyOutcome) {
        if outcome.requestPermission {
            // The completion runs on Apple's notify queue. A MainActor
            // closure traps (SIGTRAP) and the extra vanishes.
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
        }
        for alert in outcome.alerts {
            let id = alert.serial.isEmpty ? "printer" : alert.serial
            post(
                id: "pg.\(alert.kind.rawValue).\(id)",
                title: alert.title,
                body: alert.body,
                trigger: finishTrigger(alert)
            )
        }
    }

    private func finishTrigger(_ alert: PrintNotifyAlert) -> UNNotificationTrigger? {
        guard alert.kind == .finish, notifyPrefs.quietHours else { return nil }
        let now = Date()
        guard QuietHours.contains(now) else { return nil }
        let fire = QuietHours.nextMorning(from: now)
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fire
        )
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }

    private func deliverComingOff(_ action: ComingOffAction) {
        let center = UNUserNotificationCenter.current()
        if !action.cancelIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: action.cancelIds)
        }
        guard action.immediate || action.interval != nil else { return }
        let trigger: UNNotificationTrigger?
        if action.immediate {
            trigger = nil
        } else if let interval = action.interval {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        } else {
            trigger = nil
        }
        post(id: action.identifier, title: action.title, body: action.body, trigger: trigger)
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
