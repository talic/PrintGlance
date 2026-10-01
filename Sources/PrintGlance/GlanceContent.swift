import Foundation

struct StripPresentation: Equatable, Hashable, Sendable {
    var systemImage: String
    var title: String
    var accessibilityLabel: String
}

struct AMSGroup: Equatable {
    var header: String?
    var trays: [AMSTray]
}

struct GlanceContent: Equatable, Sendable {
    var result: FeedResult

    var row: Printer? {
        if case let .doc(doc) = result {
            return doc.displayRow()
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
            guard let row = doc.displayRow() else {
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

    static func strip(
        row: Printer,
        occupancyEndedAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> StripPresentation {
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
            let seen = row.lastSeen.map { "last update \(dayTime($0, now: now, calendar: calendar, locale: locale))" }
            return StripPresentation(
                systemImage: offlineImage,
                title: "",
                accessibilityLabel: [row.name, "offline", seen].compactMap { $0 }.joined(separator: ", ")
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

    /// Notifications for this app in System Settings. Undocumented: an unknown `id` opens the Notifications page.
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "local.PrintGlance")"
    )!

    /// "Quiet Hours (10 PM–7 AM)", or "(22:00–07:00)" where the Mac uses a 24-hour clock.
    static func quietHoursTitle(locale: Locale = .autoupdatingCurrent) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        let unquoted = pattern.replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression)
        let twelve = unquoted.contains("h") || unquoted.contains("K")
        func hour(_ h: Int) -> String {
            twelve ? "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")" : String(format: "%02d:00", h)
        }
        return "Quiet Hours (\(hour(QuietHours.startHour))–\(hour(QuietHours.endHour)))"
    }

    /// A printer list row's right side: "52% · 4:25 PM" while printing, else the state word.
    static func listDetail(_ row: Printer) -> String {
        guard row.state.uppercased() == "RUNNING", let pct = row.percent else { return humanState(row.state) }
        guard let eta = row.eta, !eta.isEmpty else { return "\(pct)%" }
        return "\(pct)% · \(eta)"
    }

    /// The job name while there is a job to talk about (offline: the last known state); otherwise the printer name.
    static func headline(_ row: Printer) -> String {
        var st = row.state.uppercased()
        if st == "OFFLINE" { st = row.lastState?.uppercased() ?? "" }
        guard ["PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED"].contains(st),
              let job = row.job, !job.isEmpty
        else { return row.name }
        return job
    }

    /// What we last knew about an offline printer, newest fact first.
    static func offlineLines(
        _ row: Printer,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> [String] {
        guard row.state.uppercased() == "OFFLINE", let seen = row.lastSeen else { return [] }
        func at(_ date: Date) -> String { dayTime(date, now: now, calendar: calendar, locale: locale) }
        var lines = ["Last update \(at(seen))"]
        switch row.lastState?.uppercased() {
        case "RUNNING", "PREPARE":
            let was = ["Was printing", row.percent.map { "\($0)%" }, layerLine(row)]
            lines.append(was.compactMap { $0 }.joined(separator: " · "))
            if let s = row.remainingS, s > 0 {
                let due = seen + TimeInterval(s)
                lines.append(due > now ? "Expected to finish \(at(due))" : "Was due to finish \(at(due))")
            }
        case "PAUSE":
            lines.append(row.percent.map { "Was paused at \($0)%" } ?? "Was paused")
        default:
            break
        }
        return lines
    }

    /// The printer name under a finished or failed job's hero.
    static func caption(_ row: Printer) -> String? {
        guard ["FINISH", "FAILED"].contains(row.state.uppercased()), headline(row) != row.name else {
            return nil
        }
        return row.name
    }

    /// Paused and failed only: `print_error` can stay set after the problem is gone.
    static func errorCodes(_ row: Printer) -> [String] {
        guard ["PAUSE", "FAILED"].contains(row.state.uppercased()) else { return [] }
        var codes: [String] = []
        for code in [row.hmsCode, row.printError] {
            if let code, !code.isEmpty, !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// The plain reason for the first code that has one.
    static func errorReason(_ row: Printer) -> String? {
        errorCodes(row).lazy.compactMap(errorReason(code:)).first
    }

    /// A short reason in our words for a common code. Nil for every other code, which keeps "Error <code>".
    /// AMS codes carry the unit in the first group's low byte and, for feed and filament parts, the slot in
    /// the second group's second digit (Bambu Studio's DevHMS.cpp); the table holds unit A, slot 1.
    static func errorReason(code: String) -> String? {
        let parts = code.split(separator: "-")
        var groups = parts.compactMap { UInt16($0, radix: 16) }
        guard groups.count == parts.count, groups.count == 2 || groups.count == 4 else { return nil }
        let module = Int(groups[0] >> 8)
        let unit = Int(groups[0] & 0xFF) & (module == 0x18 ? 0x7F : 0xFF)
        var place: String?
        if [0x07, 0x12, 0x18].contains(module), unit < 8 {
            // AMS HT units are ids 128 and up in reports, so they get P0's HT-A labels.
            place = "AMS \(BambuPrint.unitLabel(module == 0x18 ? 128 + unit : unit))"
            groups[0] = UInt16(module << 8)
            if groups.count == 4, [1, 2, 6, 7].contains(groups[1] >> 12) {
                if module != 0x18 { place? += ", slot \((groups[1] >> 8 & 0xF) + 1)" }
                groups[1] &= 0xF0FF
            }
        }
        let key = groups.map { String(format: "%04X", $0) }.joined(separator: "-")
        return reasons[key].map { $0.replacingOccurrences(of: "{where}", with: place ?? "the AMS") }
    }

    // ponytail: about 30 common pause and failure reasons, cross-checked with Bambu's per-model code
    // dictionaries; add a row when a code shows up often. Each row is the HMS and print_error forms.
    private static let reasons: [String: String] = {
        let heater = { (part: String, last: Int) in (1...last).map { "0300-\(part)-0001-000\($0)" } }
        let rows: [([String], String)] = [
            (["0700-2000-0002-0001", "1200-2000-0002-0001", "1800-2000-0002-0001", "0700-8011", "1200-8011", "1800-8011"],
             "Filament ran out in {where}."),
            (["07FF-2000-0002-0001", "07FE-2000-0002-0001", "12FF-2000-0002-0001", "07FF-8011", "07FE-8011", "12FF-8011"],
             "The external spool ran out of filament."),
            (["0300-8004"], "Filament ran out."),
            (["0700-7000-0002-0004", "0700-8004"], "Couldn't pull the filament back into {where}."),
            (["0700-7000-0002-0005", "0700-8005"], "Couldn't feed filament out of {where}."),
            (["0700-7000-0002-0002", "0700-8006"], "Filament from {where} didn't reach the toolhead."),
            (["0700-7000-0002-0003", "0700-8007"], "Filament reached the nozzle but didn't come out. The nozzle may be clogged."),
            (["0700-0100-0002-0002", "0700-8010"], "The feed motor in {where} is overloaded. A spool may be tangled or stuck."),
            (["0700-7000-0002-0006", "0700-8013"], "Flushing out the old filament took too long."),
            (["0700-2000-0002-0004"], "Filament from {where} may have snapped in the toolhead."),
            (["0700-6000-0002-0001"], "The spool in {where} may be tangled."),
            (["0700-8001", "07FF-8001", "07FE-8001", "1200-8001"], "The filament wasn't cut. Check that the cutter moves freely."),
            (["0700-4500-0002-0003", "0700-8002", "07FF-8002", "0300-800B"], "The filament cutter is stuck."),
            (["0300-4008"], "A filament change failed, so the print stopped."),
            (["0300-1A00-0002-0002", "0300-8016", "0300-4006"], "The nozzle may be clogged."),
            (["0300-1A00-0002-0001", "0300-8014"], "Filament may be wrapped around the nozzle, or the plate isn't sitting flat."),
            (["0C00-0300-0003-000D", "0300-800D", "0300-801A"], "Extrusion may have stopped. Check the filament and the nozzle."),
            (["0300-0900-0002-0002", "0300-801C"], "The extruder is meeting resistance. The nozzle may be clogged."),
            (["0C00-0300-0003-0007", "0300-8002", "0C00-8001"], "First-layer inspection found possible defects."),
            (["0C00-0300-0003-0008", "0300-8003", "0C00-8042"], "The camera spotted what looks like spaghetti."),
            (["0C00-0300-0003-0006", "0300-800A", "0C00-8005"], "Purged filament is piling up at the chute."),
            (["0C00-0300-0002-000C", "0300-8006", "0C00-8009", "0500-8062"], "The build plate is missing or out of place."),
            (["0300-8011", "0500-8051"], "The build plate isn't the one the file was sliced for."),
            (["0500-0400-0003-0008", "0300-9600-0001-0001", "0300-800F", "0300-8042"], "The door was opened."),
            (["0300-9700-0001-0001", "0300-404B"], "The door or top lid was opened."),
            (["0300-1200-0002-0001", "0300-8005"], "The toolhead's front cover came off."),
            (heater("0200", 7) + heater("1E00", 7) + ["0300-8008"], "The nozzle heater or its sensor has a fault."),
            (heater("0100", 8) + ["0300-8009"], "The heatbed heater or its sensor has a fault."),
            (["0300-9000-0001-0002", "0300-9300-0001-0001", "0300-9400-0002-0003", "0300-8018"], "The chamber couldn't heat properly."),
            (["0300-806E"], "The nozzle overheated. Turn the printer off and have it checked."),
            (["0300-806F"], "The heatbed overheated. Turn the printer off and have it checked."),
            (["0300-400C"], "The print was canceled."),
            (["0300-8001"], "The print was paused on the printer or in an app."),
            (["0300-8013"], "The print file asked to pause here."),
        ]
        var out: [String: String] = [:]
        for (codes, text) in rows {
            for code in codes { out[code] = text }
        }
        return out
    }()

    /// Bambu's page for a code. HMS codes have one (Bambu Studio's get_hms_wiki_url);
    /// `print_error` codes only appear in a table, so the caller also copies the code.
    static func errorLookup(code: String, serial: String) -> (url: URL, copiesCode: Bool) {
        let hex = code.replacingOccurrences(of: "-", with: "")
        if hex.count == 16 {
            // `d` routes to the right model's page; the serial's first three characters name the model.
            var c = URLComponents(string: "https://e.bambulab.com/index.php")!
            c.queryItems = [
                URLQueryItem(name: "e", value: hex),
                URLQueryItem(name: "d", value: String(serial.prefix(3))),
                URLQueryItem(name: "s", value: "device_hms"),
                URLQueryItem(name: "lang", value: "en"),
            ]
            return (c.url!, false)
        }
        // A text fragment scrolls to the row in browsers that support it; "-" must be escaped there.
        let fragment = code.replacingOccurrences(of: "-", with: "%2D")
        return (URL(string: "https://wiki.bambulab.com/en/hms/error-code#:~:text=\(fragment)")!, true)
    }

    /// AMS humidity index runs 1 (wet) to 5 (dry): Bambu Studio's legend (AmsMappingPopup.cpp) and
    /// its percent mapping (AMSItem.cpp: under 20% is 5, under 40% is 4, under 60% is 3).
    static func humidityText(_ unit: AMSUnit) -> String? {
        if let p = unit.humidityPercent { return "\(p)%" }
        switch unit.humidityLevel {
        case 4, 5: return "Dry"
        case 3: return "OK"
        case 1, 2: return "Humid"
        default: return nil
        }
    }

    /// Trays under "AMS A · Dry" headers when there is more than one unit or a humidity to show.
    /// External spools come last, without a header.
    static func amsGroups(_ row: Printer) -> [AMSGroup] {
        let trays = row.trays ?? []
        let units = row.amsUnits ?? []
        var ids: [String] = []
        for case let id? in trays.map(\.unit) where !ids.contains(id) {
            ids.append(id)
        }
        let headed = ids.count > 1 || units.contains { humidityText($0) != nil }
        var groups = ids.map { id in
            let humidity = units.first { $0.id == id }.flatMap(humidityText)
            return AMSGroup(
                header: headed ? ["AMS \(id)", humidity].compactMap { $0 }.joined(separator: " · ") : nil,
                trays: trays.filter { $0.unit == id }
            )
        }
        let loose = trays.filter { $0.unit == nil }
        if !loose.isEmpty {
            groups.append(AMSGroup(header: nil, trays: loose))
        }
        return groups
    }

    /// "X2D · 14:02 yesterday · 4h 43m · Finished". The printer name only when the log has several printers.
    static func historyCaption(
        _ row: JobLogRow,
        showPrinter: Bool,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let outcome = row.outcome.map { $0 == JobLog.outcomeFail ? "Failed" : "Finished" } ?? "Printing"
        return [
            showPrinter ? row.name : nil,
            dayTime(row.startAt, now: now, calendar: calendar, locale: locale),
            row.endedAt.map { formatRemain(max(0, Int($0.timeIntervalSince(row.startAt)))) },
            outcome,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func trayLine(_ tray: AMSTray) -> String {
        let label = tray.label ?? tray.id
        let name = tray.name.map { "\(label) · \($0)" } ?? label
        return tray.remain.map { "\(name)  \($0)%" } ?? name
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

    /// "Nozzle 186 / 220° · Bed 48 / 60°" while starting. A heater without a target shows only its
    /// temperature; the chamber shows only while it heats.
    static func heatLine(_ row: Printer) -> String? {
        guard row.state.uppercased() == "PREPARE" else { return nil }
        func reading(_ name: String, _ temp: Temp?) -> String? {
            guard let temp else { return nil }
            return temp.target > 0 ? "\(name) \(temp.current) / \(temp.target)°" : "\(name) \(temp.current)°"
        }
        let chamber = row.chamberTemp.flatMap { $0.target > 0 ? reading("Chamber", $0) : nil }
        let parts = [reading("Nozzle", row.nozzleTemp), reading("Bed", row.bedTemp), chamber].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        // Status reads need no LAN Only or Developer Mode (Bambu's third-party integration page),
        // so a refusal means the wrong host or a printer that is still booting.
        if r.contains("ECONNREFUSED") {
            return "The printer refused the connection. It may still be starting up, or another device may have its IP address now. Check the IP address on the printer's LAN or Network page."
        }
        if codeRejected(reason) {
            return "The access code was rejected. Check the access code on the printer's LAN or Network page."
        }
        return "Can't reach the printer. Check Wi-Fi and the IP address."
    }

    /// The printer answered and refused the access code.
    static func codeRejected(_ reason: String?) -> Bool {
        reason?.hasPrefix("MQTT CONNACK") == true
    }
}
