import Foundation

// The iPhone app and widget (`iOS/`) compile this file with the Foundation-only files it needs from this
// target. It lives here so `make test` covers it; the Mac app doesn't call it.

/// The iPhone's last look at its printer: the row as the printer reported it, and when.
struct PhoneStatus: Codable, Equatable, Sendable {
    var printer: Printer
    var at: Date
}

/// The printer and its last status, shared by the iPhone app and widget through their App Group.
struct PhoneStore {
    let defaults: UserDefaults

    static let statusKey = "pg.phone.status"

    /// The App Group that Info.plist names in `PGAppGroup`. Nil where there is none (the Mac app, tests), and
    /// when signing left the entitlement out: then iOS would hand each process its own private defaults.
    static var shared: PhoneStore? {
        guard let group = appGroup,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let d = UserDefaults(suiteName: group)
        else { return nil }
        return PhoneStore(defaults: d)
    }

    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "PGAppGroup") as? String
    }

    // ponytail: one printer on the iPhone. SavedPrinters holds four; add a list when someone has two.
    var printer: PrinterSettings? {
        SavedPrinters.load(from: defaults).printers.first
    }

    /// Saving a different printer forgets the old one's status.
    func save(_ printer: PrinterSettings) {
        if self.printer?.serial != printer.trimmed.serial { save(nil) }
        SavedPrinters(printers: [printer.trimmed], focusId: nil).save(to: defaults)
    }

    var status: PhoneStatus? {
        defaults.data(forKey: Self.statusKey).flatMap { try? JSONDecoder().decode(PhoneStatus.self, from: $0) }
    }

    func save(_ status: PhoneStatus?) {
        defaults.set(status.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.statusKey)
    }
}

/// One look at a printer: connect, ask for a full report, hang up. The iPhone can't hold a connection
/// open like the Mac, so the app and the widget each ask when they run.
enum PrinterFetch {
    enum Outcome: Equatable, Sendable {
        case printer(Printer)
        /// The client's reason, as `GlanceCopy.feedDownDetail` reads it.
        case failed(String?)
    }

    @MainActor
    static func fetch(
        _ settings: PrinterSettings,
        client: any MQTTSession = MQTT311Client(),
        timeout: Duration = .seconds(8)
    ) async -> Outcome {
        let p = settings.trimmed
        guard p.isComplete else { return .failed(nil) }
        let snapshot = BambuSnapshot(printerID: p.serial, name: p.displayName)
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            let once = Once(done)
            client.onConnect = {
                client.subscribe("device/\(p.serial)/report")
                client.publish(
                    topic: "device/\(p.serial)/request",
                    payload: Data(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8)
                )
            }
            client.onMessage = { _, data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                snapshot.ingest(obj)
                // ponytail: the first report with a state counts as the full one, which `pushall` sends at
                // once. A delta carrying `gcode_state` first would leave fields out until the next look.
                if BambuJSON.stringValue(snapshot.printObj["gcode_state"]) != nil {
                    once.finish(.printer(snapshot.printer()))
                }
            }
            client.onDisconnect = { once.finish(.failed($0)) }
            // Before `connect`, so a client that answers at once still cancels it.
            once.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { once.finish(.failed("connect timed out")) }
            }
            client.connect(
                host: p.ip,
                port: 8883,
                clientID: "pg-phone-\(p.serial.suffix(6))-\(String(UInt16.random(in: .min ... .max), radix: 16))",
                username: "bblp",
                password: p.accessCode
            )
        }
        client.onConnect = nil
        client.onMessage = nil
        client.onDisconnect = nil
        client.disconnect()
        return outcome
    }

    /// Resumes the fetch with whichever of report, drop, or timeout comes first.
    @MainActor
    private final class Once {
        private var done: CheckedContinuation<Outcome, Never>?
        var timer: Task<Void, Never>?
        init(_ done: CheckedContinuation<Outcome, Never>) { self.done = done }
        func finish(_ outcome: Outcome) {
            timer?.cancel()
            done?.resume(returning: outcome)
            done = nil
        }
    }
}

/// What the iPhone widget and app show. Every string comes from here.
struct PhoneLines: Equatable, Sendable {
    var title: String
    /// Printing, the stage while starting, Paused, …
    var state: String
    /// The finish time, or time left while paused.
    var hero: String? = nil
    /// "1h 24m left" under a finish time, or why a print stopped.
    var detail: String? = nil
    /// The bar, while a print is under way.
    var percent: Int? = nil
    /// Layer and filament, where there is room.
    var extra: [String] = []
    /// "Updated 14:02": the widget only knows what the printer said then.
    var footer: String? = nil
    /// One line for the Lock Screen: "52% · 16:25".
    var short: String
    /// The menu bar's symbol for this state.
    var systemImage: String = "printer"
    /// Paused or failed: the state and bar turn orange.
    var alert = false
}

extension GlanceContent {
    /// The iPhone has no live link, so times count from the moment the printer answered (`status.at`).
    static func phone(
        _ status: PhoneStatus?,
        hasPrinter: Bool,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> PhoneLines {
        guard hasPrinter else {
            return PhoneLines(title: "Add your printer", state: "", detail: "Open PrintGlance to set it up.", short: "Add your printer")
        }
        guard let status else {
            return PhoneLines(
                title: "Can't reach printer",
                state: "",
                detail: "PrintGlance updates when this iPhone is on the printer's Wi-Fi.",
                short: "Can't reach printer",
                systemImage: offlineImage
            )
        }
        func at(_ date: Date) -> String { dayTime(date, now: now, calendar: calendar, locale: locale) }
        let row = status.printer
        let st = row.state.uppercased()
        var lines = PhoneLines(
            title: headline(row),
            state: subtitle(row),
            footer: "Updated \(at(status.at))",
            short: humanState(st),
            systemImage: strip(row: row).systemImage,
            alert: st == "PAUSE" || st == "FAILED"
        )
        switch st {
        case "RUNNING", "PREPARE":
            if let s = row.remainingS, s > 0 {
                let end = status.at + TimeInterval(s)
                // Whole minutes, rounded up, so a moment after the printer said 84 minutes it still says 1h 24m.
                let left = Int((end.timeIntervalSince(now) / 60).rounded(.up)) * 60
                lines.hero = at(end)
                lines.detail = left > 0 ? "\(formatRemain(left)) left" : "Should be done"
            }
        case "PAUSE":
            lines.hero = hero(row)
            lines.detail = errorReason(row)
        case "FAILED":
            lines.detail = errorReason(row)
        case "FINISH":
            lines.detail = caption(row)
        default:
            break
        }
        if isTimed(st) {
            lines.percent = row.percent
            lines.extra = [layerLine(row), filamentLine(row)].compactMap { $0 }
            let pct = row.percent.map { "\($0)%" }
            let parts: [String?] = switch st {
            case "PREPARE": [shortStage(row.stage), lines.hero]
            case "PAUSE": ["Paused", pct]
            default: [pct, lines.hero]
            }
            lines.short = parts.compactMap { $0 }.joined(separator: " · ")
        }
        return lines
    }

    /// When the widget redraws: each minute while a finish time counts down, for up to two hours.
    static func phoneEntryDates(_ status: PhoneStatus?, now: Date) -> [Date] {
        guard let status, ["RUNNING", "PREPARE"].contains(status.printer.state.uppercased()),
              let s = status.printer.remainingS, s > 0
        else { return [now] }
        let left = status.at.timeIntervalSince(now) + TimeInterval(s)
        let minutes = min(120, max(0, Int(left / 60) + 1))
        return (0 ... minutes).map { now + TimeInterval($0 * 60) }
    }

    /// When the widget asks the printer again: every 15 minutes during a print (or just after its finish
    /// time, if sooner), else hourly. iOS decides when it really does.
    static func phoneNextFetch(_ status: PhoneStatus?, now: Date) -> Date {
        guard let status, isTimed(status.printer.state) else { return now + 3600 }
        let soon = now + 15 * 60
        guard status.printer.state.uppercased() != "PAUSE", let s = status.printer.remainingS, s > 0 else { return soon }
        let end = status.at + TimeInterval(s) + 60
        return end > now ? min(soon, end) : soon
    }
}

extension GlanceCopy {
    /// The iPhone also needs Local Network access, which iOS asks for once and Settings can turn off.
    static func phoneFetchFailed(reason: String?) -> String {
        guard !codeRejected(reason), reason?.contains("ECONNREFUSED") != true else {
            return feedDownDetail(reason: reason)
        }
        return "Can't reach the printer. Check that this iPhone is on the printer's Wi-Fi, and check the IP address. PrintGlance also needs Local Network access in Settings."
    }
}
