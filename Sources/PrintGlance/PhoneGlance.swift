import Foundation
import Network

// The iPhone app and widget (`iOS/`) compile this file with the Foundation-only files it needs from this
// target. It lives here so `make test` covers it; the Mac app doesn't call it.

/// The iPhone's last look at a printer: the row as the printer reported it, and when.
struct PhoneStatus: Codable, Equatable, Sendable {
    var printer: Printer
    var at: Date
}

/// The printers (up to four, like the Mac) and their last statuses, shared by the iPhone app and widget
/// through their App Group.
struct PhoneStore {
    let defaults: UserDefaults

    static let statusesKey = "pg.phone.statuses"

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

    var printers: [PrinterSettings] {
        SavedPrinters.load(from: defaults).printers
    }

    /// The statuses of printers no longer in the list go too.
    func save(_ printers: [PrinterSettings]) {
        let list = printers.map(\.trimmed)
        SavedPrinters(printers: list, focusId: nil).save(to: defaults)
        save(statuses.filter { status in list.contains { $0.serial == status.printer.id } })
    }

    var statuses: [PhoneStatus] {
        defaults.data(forKey: Self.statusesKey).flatMap { try? JSONDecoder().decode([PhoneStatus].self, from: $0) } ?? []
    }

    func save(_ statuses: [PhoneStatus]) {
        defaults.set(try? JSONEncoder().encode(statuses), forKey: Self.statusesKey)
    }

    /// Each printer that answered replaces its last status; the rest keep theirs.
    // ponytail: read, change, write. The app and widget saving at the same moment can lose one status until
    // the next look; a file with a lock is the upgrade if that ever shows.
    func record(_ outcomes: [String: PrinterFetch.Outcome], at date: Date) {
        var fresh: [PhoneStatus] = []
        for case let .printer(row) in outcomes.values { fresh.append(PhoneStatus(printer: row, at: date)) }
        save(statuses.filter { old in !fresh.contains { $0.printer.id == old.printer.id } } + fresh)
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

    /// Every printer at once, by serial, so a widget reload takes one timeout at most.
    @MainActor
    static func fetchAll(
        _ printers: [PrinterSettings],
        makeClient: () -> any MQTTSession = { MQTT311Client() },
        timeout: Duration = .seconds(8)
    ) async -> [String: Outcome] {
        let looks = printers.map { printer in
            let client = makeClient()
            return (printer.trimmed.serial, Task { await fetch(printer, client: client, timeout: timeout) })
        }
        var outcomes: [String: Outcome] = [:]
        for (serial, look) in looks { outcomes[serial] = await look.value }
        return outcomes
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

/// Finds printers on the iPhone's Wi-Fi. iOS allows the Mac's SSDP multicast only with Apple's approval,
/// so this tries the MQTT port on each neighbor and reads the serial from the printer's certificate, whose
/// common name is the serial. It never logs in and sends nothing; the access code is still typed.
enum PrinterSearch {
    /// Printers that answered, by IP, with only `ip` and `serial` set. Every probe runs at once, so a search
    /// takes about `timeout`.
    static func scan(timeout: TimeInterval = 3) async -> [PrinterSettings] {
        guard let wifi = wifi() else { return [] }
        return await withTaskGroup(of: PrinterSettings?.self) { group in
            for host in neighbors(ip: wifi.ip, netmask: wifi.netmask) {
                group.addTask {
                    serial(fromCommonName: await commonName(host: host, timeout: timeout))
                        .map { PrinterSettings(ip: host, serial: $0, accessCode: "", name: "") }
                }
            }
            var found: [PrinterSettings] = []
            for await hit in group {
                if let hit { found.append(hit) }
            }
            return found.sorted { (ipv4($0.ip) ?? 0) < (ipv4($1.ip) ?? 0) }
        }
    }

    /// Every other host in the iPhone's subnet.
    static func neighbors(ip: String, netmask: String) -> [String] {
        guard let address = ipv4(ip), let given = ipv4(netmask) else { return [] }
        // ponytail: at most the /24 around the iPhone, not a /16's 65,000 hosts. Bigger home networks
        // keep typing the IP address.
        let mask = max(given, 0xFFFF_FF00)
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return (network + 1 ..< broadcast).filter { $0 != address }.map(dotted)
    }

    /// A Bambu serial such as 01P00A123456789. Anything else on the MQTT port, like a home MQTT broker,
    /// has a host name in its certificate instead.
    static func serial(fromCommonName name: String?) -> String? {
        guard let name, (8 ... 20).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) })
        else { return nil }
        return name
    }

    /// Opens TLS to one host and returns its certificate's common name. Nil when nothing answers in time.
    static func commonName(host: String, port: UInt16 = 8883, timeout: TimeInterval = 3) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let probe = Probe(done)
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, trust, complete in
                    probe.name = leafCommonName(sec_trust_copy_ref(trust).takeRetainedValue())
                    complete(true)
                },
                probe.queue
            )
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 8883,
                using: NWParameters(tls: tls)
            )
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled: probe.finish(conn)
                default: break // .waiting covers a refused port and the Local Network prompt; the timeout ends it
                }
            }
            conn.start(queue: probe.queue)
            probe.queue.asyncAfter(deadline: .now() + timeout) { probe.finish(conn) }
        }
    }

    private static func leafCommonName(_ trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        return name as String?
    }

    /// The iPhone's Wi-Fi address and mask (`en0`).
    private static func wifi() -> (ip: String, netmask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard String(cString: ifa.ifa_name) == "en0", let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            return (dotted(inet(addr)), dotted(inet(mask)))
        }
        return nil
    }

    private static func inet(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func dotted(_ n: UInt32) -> String {
        [24, 16, 8, 0].map { String((n >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    /// One probe's state, touched only on its queue.
    private final class Probe: @unchecked Sendable {
        let queue = DispatchQueue(label: "local.PrintGlance.search")
        var name: String?
        private var done: CheckedContinuation<String?, Never>?
        init(_ done: CheckedContinuation<String?, Never>) { self.done = done }
        func finish(_ conn: NWConnection) {
            conn.stateUpdateHandler = nil
            conn.cancel()
            done?.resume(returning: name)
            done = nil
        }
    }
}

/// What the iPhone widget and app show. Every string comes from here.
struct PhoneLines: Equatable, Sendable {
    /// The printer's serial; empty before one is added.
    var id = ""
    var title: String
    /// Printing, the stage while starting, Paused, …, after the printer's name when a job is the title.
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
    /// Every saved printer's card, the one that needs you first, ranked like the Mac's menu bar. A printer
    /// never reached counts as offline. With no printers, one card says to add one.
    static func phoneCards(
        _ printers: [PrinterSettings],
        statuses: [PhoneStatus],
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> [PhoneLines] {
        guard !printers.isEmpty else { return [phone(nil, printer: nil, now: now)] }
        func status(_ p: PrinterSettings) -> PhoneStatus? { statuses.first { $0.printer.id == p.trimmed.serial } }
        let rows = printers.map { p in
            status(p)?.printer ?? Printer(
                id: p.trimmed.serial, name: p.displayName, state: "OFFLINE", percent: nil, remainingS: nil,
                job: nil, layer: nil, layerTotal: nil, eta: nil, filament: nil, filamentRemain: nil
            )
        }
        return PrintDoc(v: 1, printers: rows).ranked().compactMap { row in
            printers.first { $0.trimmed.serial == row.id }.map {
                phone(status($0), printer: $0, now: now, calendar: calendar, locale: locale)
            }
        }
    }

    /// One printer's card. The iPhone has no live link, so times count from the moment the printer
    /// answered (`status.at`). Nil `printer` is the card that asks to add one.
    static func phone(
        _ status: PhoneStatus?,
        printer: PrinterSettings?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> PhoneLines {
        guard let printer else {
            return PhoneLines(title: "Add your printer", state: "", detail: "Open PrintGlance to set it up.", short: "Add your printer")
        }
        guard let status else {
            return PhoneLines(
                id: printer.trimmed.serial,
                title: printer.displayName,
                state: "Can't reach printer",
                detail: "PrintGlance updates when this iPhone is on the printer's Wi-Fi.",
                short: "Can't reach printer",
                systemImage: offlineImage
            )
        }
        func at(_ date: Date) -> String { dayTime(date, now: now, calendar: calendar, locale: locale) }
        let row = status.printer
        let st = row.state.uppercased()
        let title = headline(row)
        var lines = PhoneLines(
            id: row.id,
            title: title,
            // With a job in the title, name the printer, so two printers' cards tell apart.
            state: title == row.name ? subtitle(row) : "\(row.name) · \(subtitle(row))",
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

    /// When the widget redraws: each minute while any finish time counts down, for up to two hours.
    static func phoneEntryDates(_ statuses: [PhoneStatus], now: Date) -> [Date] {
        let minutes = statuses.map { status -> Int in
            guard ["RUNNING", "PREPARE"].contains(status.printer.state.uppercased()),
                  let s = status.printer.remainingS, s > 0
            else { return 0 }
            let left = status.at.timeIntervalSince(now) + TimeInterval(s)
            return min(120, max(0, Int(left / 60) + 1))
        }.max() ?? 0
        return (0 ... minutes).map { now + TimeInterval($0 * 60) }
    }

    /// When the widget asks the printers again: every 15 minutes while any prints (or just after the first
    /// finish time, if sooner), else hourly. iOS decides when it really does.
    static func phoneNextFetch(_ statuses: [PhoneStatus], now: Date) -> Date {
        statuses.map { status -> Date in
            guard isTimed(status.printer.state) else { return now + 3600 }
            let soon = now + 15 * 60
            guard status.printer.state.uppercased() != "PAUSE", let s = status.printer.remainingS, s > 0 else { return soon }
            let end = status.at + TimeInterval(s) + 60
            return end > now ? min(soon, end) : soon
        }.min() ?? now + 3600
    }
}

extension PrinterSettings {
    /// The iPhone form after tapping a printer the search found: its IP and serial, and a code and name only
    /// if they belong to it. Keeping another printer's code would send it to this one, which rejects it.
    func picking(_ hit: PrinterSettings, saved: [PrinterSettings]) -> PrinterSettings {
        let own = trimmed.serial == hit.serial ? self : saved.first { $0.serial == hit.serial }
        return PrinterSettings(ip: hit.ip, serial: hit.serial, accessCode: own?.accessCode ?? "", name: own?.name ?? "")
    }
}

/// An alert in the iPhone app.
struct PhoneAlert: Equatable, Sendable {
    var title: String
    var message: String
}

extension GlanceCopy {
    /// After **Connect**: it worked, or why not.
    static func phoneConnected(_ outcome: PrinterFetch.Outcome, name: String) -> PhoneAlert {
        switch outcome {
        case .printer:
            return PhoneAlert(
                title: "Connected to \(name)",
                message: "Its status shows at the top of this screen. To see it on your Home Screen, add the PrintGlance widget."
            )
        case let .failed(reason):
            return PhoneAlert(title: "Can't connect to \(name)", message: phoneFetchFailed(reason: reason))
        }
    }

    /// **Connect** with four printers saved already, the Mac's limit too.
    static func phoneTooMany(name: String) -> PhoneAlert {
        PhoneAlert(
            title: "Can't add \(name)",
            message: "PrintGlance watches up to four printers. To add this one, swipe left on another and remove it."
        )
    }

    /// The iPhone also needs Local Network access, which iOS asks for once and Settings can turn off.
    static func phoneFetchFailed(reason: String?) -> String {
        guard !codeRejected(reason), reason?.contains("ECONNREFUSED") != true else {
            return feedDownDetail(reason: reason)
        }
        return "Can't reach the printer. Check that this iPhone is on the printer's Wi-Fi, and check the IP address. PrintGlance also needs Local Network access in Settings."
    }
}
