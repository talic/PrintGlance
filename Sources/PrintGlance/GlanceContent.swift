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

    /// `feedDownReason` is why the links failed before any printer reported: only a rejected code keeps
    /// `wifi.slash` then, since a printer switched off overnight is the usual reason.
    static func strip(
        _ result: FeedResult,
        occupancyEndedAt: Date? = nil,
        now: Date = Date(),
        feedDownReason: String? = nil
    ) -> StripPresentation {
        switch result {
        case .feedDown:
            return StripPresentation(
                systemImage: GlanceCopy.codeRejected(feedDownReason) ? offlineImage : switchedOffImage,
                title: "",
                accessibilityLabel: "Can't reach printer"
            )
        case .needsSetup:
            return StripPresentation(
                systemImage: "printer",
                title: "Set Up",
                accessibilityLabel: "Add your Bambu printer"
            )
        case .connecting:
            return StripPresentation(
                systemImage: "printer",
                title: "…",
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
    /// A printer that is probably switched off: nothing to fix, so no slash.
    static let switchedOffImage = "powersleep"
    /// The menu bar drops "40m ago" after this; the checkmark stays.
    static let finishTitleFor: TimeInterval = 2 * 3600

    static func strip(
        row: Printer,
        occupancyEndedAt: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> StripPresentation {
        switch row.printState {
        case .starting:
            return StripPresentation(
                systemImage: "printer.fill",
                title: shortStage(row.stage),
                accessibilityLabel: a11y(row)
            )
        case .printing:
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
        case .paused:
            return StripPresentation(
                systemImage: "pause.fill",
                title: paddedPercent(row.percent) ?? "",
                accessibilityLabel: a11y(row)
            )
        case .finished:
            let ago = occupancyEndedAt.map { agoTitle(from: $0, now: now) }
            let fresh = occupancyEndedAt.map { now.timeIntervalSince($0) < finishTitleFor } ?? false
            return StripPresentation(
                systemImage: "checkmark",
                title: fresh ? ago ?? "" : "",
                accessibilityLabel: a11y(row, ago: ago)
            )
        case .failed:
            return StripPresentation(
                systemImage: isCanceled(row) ? "stop.circle" : "xmark",
                title: "",
                accessibilityLabel: a11y(row)
            )
        case .offline:
            let seen = row.lastSeen.map { "last update \(dayTime($0, now: now, calendar: calendar, locale: locale))" }
            return StripPresentation(
                systemImage: offlineKind(row) == .switchedOff ? switchedOffImage : offlineImage,
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

    static func humanState(_ state: PrintState) -> String {
        switch state {
        case .printing: "Printing"
        case .starting: "Starting"
        case .paused: "Paused"
        case .finished: "Finished"
        case .failed: "Failed"
        case .idle: "Idle"
        case .offline: "Offline"
        case let .other(raw): raw
        }
    }

    /// The `print_error` a cancel leaves, on the printer or from an app. Bambu reports a cancel as FAILED.
    static let cancelCode = "0300-400C"

    /// A FAILED report that is really a cancel. The row keeps FAILED, so `printers.json` still says what the
    /// printer said; only what this app shows changes.
    static func isCanceled(_ row: Printer) -> Bool {
        row.printState == .failed && errorCodes(row).contains(cancelCode)
    }

    /// A History row that ended in a cancel. `JobLog` saves the cancel code as the row's `failCode`.
    static func isCanceled(_ row: JobLogRow) -> Bool {
        row.outcome == JobLog.outcomeFail && row.failCode == cancelCode
    }

    /// A row's state as one word: Canceled for a canceled print, else `humanState`.
    static func stateWord(_ row: Printer) -> String {
        isCanceled(row) ? "Canceled" : humanState(row.printState)
    }

    /// Why an offline printer is offline, which decides its icon, rank, and words.
    enum OfflineKind: Equatable, Sendable {
        /// It was starting, printing, or paused when last heard from.
        case lost
        /// It answered and refused the access code.
        case codeRejected
        /// Idle, finished, failed, or canceled when last heard from, or never reached: most likely switched off.
        case switchedOff
    }

    /// Nil while the printer is online.
    static func offlineKind(_ row: Printer) -> OfflineKind? {
        guard row.printState == .offline else { return nil }
        if row.lastPrintState?.isTimed == true { return .lost }
        return row.codeRejected == true ? .codeRejected : .switchedOff
    }

    /// Notifications for this app in System Settings. Undocumented: an unknown `id` opens the Notifications page.
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "local.PrintGlance")"
    )!

    /// The Quiet Hours submenu: "Quiet Hours (10 PM–7 AM)", or "Quiet Hours (Off)".
    static func quietHoursTitle(_ window: QuietHours?, locale: Locale = .autoupdatingCurrent) -> String {
        "Quiet Hours (\(quietHoursChoice(window, locale: locale)))"
    }

    /// One Quiet Hours choice: "Off", "10 PM–7 AM", "Midnight–9 AM", or "22:00–07:00" where the Mac uses a 24-hour clock.
    static func quietHoursChoice(_ window: QuietHours?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let window else { return "Off" }
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        let unquoted = pattern.replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression)
        let twelve = unquoted.contains("h") || unquoted.contains("K")
        func hour(_ h: Int) -> String {
            guard twelve else { return String(format: "%02d:00", h) }
            return h == 0 ? "Midnight" : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
        }
        return "\(hour(window.startHour))–\(hour(window.endHour))"
    }

    /// The Print Finishing Soon submenu: "Print Finishing Soon (10 Min Before)", or "Print Finishing Soon (Off)".
    static func finishingSoonTitle(lead: Int?) -> String {
        "Print Finishing Soon (\(lead.map { "\($0) Min Before" } ?? "Off"))"
    }

    /// One Print Finishing Soon choice: "Off" or "10 Minutes Before".
    static func finishingSoonChoice(lead: Int?) -> String {
        lead.map { "\($0) Minutes Before" } ?? "Off"
    }

    /// A printer list row's right side: "52% · 4:25 PM" while printing, else the state word.
    static func listDetail(_ row: Printer) -> String {
        guard row.printState == .printing, let pct = row.percent else { return stateWord(row) }
        guard let eta = row.eta, !eta.isEmpty else { return "\(pct)%" }
        return "\(pct)% · \(eta)"
    }

    /// The job name while there is a job to talk about (offline: the last known state); otherwise the printer name.
    static func headline(_ row: Printer) -> String {
        let st = row.printState == .offline ? row.lastPrintState : row.printState
        guard let st, st.isTimed || st == .finished || st == .failed,
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
        guard row.printState == .offline, let seen = row.lastSeen else { return [] }
        func at(_ date: Date) -> String { dayTime(date, now: now, calendar: calendar, locale: locale) }
        var lines = ["Last update \(at(seen))"]
        switch row.lastPrintState {
        case .printing, .starting:
            let was = ["Was printing", row.percent.map { "\($0)%" }, layerLine(row)]
            lines.append(was.compactMap { $0 }.joined(separator: " · "))
            if let s = row.remainingS, s > 0 {
                let due = seen + TimeInterval(s)
                lines.append(due > now ? "Expected to finish \(at(due))" : "Was due to finish \(at(due))")
            }
        case .paused:
            lines.append(row.percent.map { "Was paused at \($0)%" } ?? "Was paused")
        default:
            break
        }
        return lines
    }

    /// The printer name under a finished or failed job's hero.
    static func caption(_ row: Printer) -> String? {
        guard [.finished, .failed].contains(row.printState), headline(row) != row.name else {
            return nil
        }
        return row.name
    }

    /// Paused and failed only: `print_error` can stay set after the problem is gone.
    static func errorCodes(_ row: Printer) -> [String] {
        guard row.printState.isStopped else { return [] }
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

    /// The code a notification or History names: the one `errorReason` explains, else the first.
    static func leadErrorCode(_ row: Printer) -> String? {
        let codes = errorCodes(row)
        return codes.first { errorReason(code: $0) != nil } ?? codes.first
    }

    /// A code's plain reason, else "Error <code>".
    static func errorLine(code: String) -> String {
        errorReason(code: code) ?? "Error \(code)"
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

    /// A History row's title: the job, else the printer's name.
    static func historyTitle(_ row: JobLogRow) -> String {
        if let job = row.job, !job.isEmpty { return job }
        return row.name
    }

    /// Printing, Finished, Failed, or Canceled.
    static func historyOutcome(_ row: JobLogRow) -> String {
        guard let outcome = row.outcome else { return "Printing" }
        if isCanceled(row) { return "Canceled" }
        return outcome == JobLog.outcomeFail ? "Failed" : "Finished"
    }

    /// Only a real failure tints its outcome word red; a cancel was someone's choice.
    static func historyFailed(_ row: JobLogRow) -> Bool {
        row.outcome == JobLog.outcomeFail && !isCanceled(row)
    }

    /// "X2D · 14:02 yesterday · 4h 43m · Finished". The printer name only when the log has several printers
    /// and the title isn't already the printer's name.
    static func historyCaption(
        _ row: JobLogRow,
        showPrinter: Bool,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let parts = historyCaptionParts(row, showPrinter: showPrinter, now: now, calendar: calendar, locale: locale)
        return parts.lead + parts.outcome
    }

    /// `historyCaption` as everything up to the outcome word ("14:02 yesterday · 4h 43m · ") and the word,
    /// so the view tints only the word.
    static func historyCaptionParts(
        _ row: JobLogRow,
        showPrinter: Bool,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> (lead: String, outcome: String) {
        let lead = [
            showPrinter && historyTitle(row) != row.name ? row.name : nil,
            dayTime(row.startAt, now: now, calendar: calendar, locale: locale),
            row.endedAt.map { formatRemain(max(0, Int($0.timeIntervalSince(row.startAt)))) },
        ].compactMap { $0 }.joined(separator: " · ")
        return (lead + " · ", historyOutcome(row))
    }

    /// Lines under a History row's caption: why it failed, then how often it paused and the last pause's reason.
    /// A cancel needs no reason: the caption already says Canceled.
    static func historyNotes(_ row: JobLogRow) -> [String] {
        var notes: [String] = []
        if row.outcome == JobLog.outcomeFail, let code = row.failCode, !code.isEmpty, code != cancelCode {
            notes.append(errorLine(code: code))
        }
        if let pauses = row.pauses, let last = pauses.last {
            let n = pauses.count
            let times = n == 1 ? "Paused once" : n == 2 ? "Paused twice" : "Paused \(n) times"
            if last.isEmpty {
                notes.append("\(times).")
            } else if n == 1 {
                notes.append("Paused: \(errorLine(code: last))")
            } else {
                notes.append("\(times). Last: \(errorLine(code: last))")
            }
        }
        return notes
    }

    /// The Clear History alert's text, for `cleared` ended prints and `running` ones that stay.
    static func clearHistoryMessage(cleared: Int, running: Int) -> String {
        let what = cleared == 1 ? "the print" : "the \(cleared) prints"
        var text = "PrintGlance forgets \(what) saved on this Mac. You can't undo this."
        if running > 0 {
            text += running == 1 ? " The print in progress stays." : " The prints in progress stay."
        }
        return text
    }

    static func trayLine(_ tray: AMSTray) -> String {
        let label = tray.label ?? tray.id
        let name = tray.name.map { "\(label) · \($0)" } ?? label
        return tray.remain.map { "\(name)  \($0)%" } ?? name
    }

    /// The reasons and codes block: always while paused, saying "No error reported." when there's no code,
    /// and while failed unless the print was canceled: the subtitle already says Canceled.
    static func showsErrors(_ row: Printer) -> Bool {
        switch row.printState {
        case .paused: return true
        case .failed: return !isCanceled(row)
        default: return false
        }
    }

    /// Trays matter when you are at the printer: before a print, after one, or on a paused runout.
    static func showsAMS(_ row: Printer) -> Bool {
        [.idle, .finished, .failed, .paused].contains(row.printState)
    }

    static func subtitle(_ row: Printer) -> String {
        if row.printState == .starting, let stage = row.stage, !stage.isEmpty {
            return stage
        }
        return stateWord(row)
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
            return english(date, DateFormats.shared.pattern("MMMd", locale), calendar)
        }
        let time = english(date, DateFormats.shared.pattern("jmm", locale), calendar)
        switch days {
        case 0: return time
        case 1: return "\(time) tomorrow"
        case -1: return "\(time) yesterday"
        default: return "\(time) \(english(date, "EEE", calendar))"
        }
    }

    /// Formats with the locale's pattern but English words (AM/PM, Mon, Sep).
    private static func english(_ date: Date, _ pattern: String?, _ calendar: Calendar) -> String {
        DateFormats.shared.string(date, pattern: pattern ?? "HH:mm", calendar: calendar)
    }


    static func agoTitle(from ended: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(ended)))
        return "\(formatRemain(s)) ago"
    }

    /// The big line. Nil when it would only repeat the subtitle.
    static func hero(_ row: Printer, occupancyEndedAt: Date? = nil, now: Date = Date()) -> String? {
        switch row.printState {
        case .printing, .starting:
            if let eta = row.eta, !eta.isEmpty { return eta }
            return row.remainingS.flatMap { $0 > 0 ? formatRemain($0) : nil }
        case .paused:
            // The finish time slides later while paused; time left holds still.
            return row.remainingS.flatMap { $0 > 0 ? "\(formatRemain($0)) left" : nil }
        case .finished:
            return occupancyEndedAt.map { agoTitle(from: $0, now: now) }
        default:
            return nil
        }
    }

    /// "1h 24m left" under a finish-time hero.
    static func remainingLine(_ row: Printer) -> String? {
        guard row.printState.isActive,
              let s = row.remainingS, s > 0, let eta = row.eta, !eta.isEmpty
        else {
            return nil
        }
        return "\(formatRemain(s)) left"
    }

    /// "Nozzle 186 / 220° · Bed 48 / 60°" while starting. A heater without a target shows only its
    /// temperature; the chamber shows only while it heats.
    static func heatLine(_ row: Printer) -> String? {
        guard row.printState == .starting else { return nil }
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

    /// "PLA Matte in A2 runs out around 15:45." under the bar, and the runout notice body.
    static func runoutLine(_ r: Runout) -> String {
        let what = [r.name ?? "Filament", r.tray.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        var line: String
        if r.soon {
            line = "\(what) is about to run out."
        } else if let at = r.at {
            line = "\(what) runs out around \(at)."
        } else {
            line = "\(what) runs out at about \(r.percent)%."
        }
        if let backup = r.backup {
            line += " AMS may switch to \(backup)."
        }
        return line
    }

    private static func a11y(_ row: Printer, ago: String? = nil) -> String {
        let st = row.printState
        let timed = st.isTimed
        var parts = [row.name, [stateWord(row).lowercased(), ago].compactMap { $0 }.joined(separator: " ")]
        if let p = row.percent, timed || st == .failed {
            parts.append("\(p) percent")
        }
        if st.isActive, let eta = row.eta, !eta.isEmpty {
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

/// Every row's finish time is formatted on every pass, and a `DateFormatter` and a template lookup are slow
/// to make: one of each per pattern, locale, and time zone, kept. A changed time zone or 12/24-hour setting is
/// a new key. The lock guards the dictionaries and the formatter in use; the widget formats off the main thread.
private final class DateFormats: @unchecked Sendable {
    static let shared = DateFormats()
    private let lock = NSLock()
    private var patterns: [String: String] = [:]
    private var formatters: [String: DateFormatter] = [:]

    /// The locale's pattern for a template, such as "HH:mm" for "jmm" in en_GB.
    func pattern(_ template: String, _ locale: Locale) -> String? {
        let key = "\(template)|\(locale.identifier)|\(locale.hourCycle)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = patterns[key] { return hit }
        let made = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        patterns[key] = made
        return made
    }

    /// English words (AM/PM, Mon, Sep) in the calendar's time zone.
    func string(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        lock.lock()
        defer { lock.unlock() }
        let f = formatters[key] ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = pattern
            formatters[key] = f
            return f
        }()
        return f.string(from: date)
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
        if let other = wrongSerial(reason) {
            return "The printer at this IP address has serial \(other). Check the serial number and the IP address on the printer's LAN or Network page."
        }
        return "Can't reach the printer. Check Wi-Fi and the IP address."
    }

    /// Under an offline printer's card, or under "Can't reach printer" (nil row) before any printer reported.
    /// A printer that was idle or done when last heard from, or never answered, is most likely switched off,
    /// so that reads calm. A print that was running and a rejected code keep `feedDownDetail`.
    static func offlineDetail(_ row: Printer?, reason: String?) -> String {
        let switchedOff = row.map { GlanceContent.offlineKind($0) == .switchedOff } ?? true
        guard switchedOff, !codeRejected(reason) else { return feedDownDetail(reason: reason) }
        // A refusal means something answers at that IP: a printer still booting, or another device.
        if reason?.contains("ECONNREFUSED") == true {
            return "It may be switched off or still starting up. If it's on, check the IP address on the printer's LAN or Network page."
        }
        return "It may be switched off. If it's on, check Wi-Fi and the IP address."
    }

    /// The serial the printer at that address named, when it isn't the one saved.
    static func wrongSerial(_ reason: String?) -> String? {
        let prefix = MQTT311Client.wrongSerialReason + " "
        guard let reason, reason.hasPrefix(prefix) else { return nil }
        return String(reason.dropFirst(prefix.count))
    }

    /// The printer answered and refused the access code.
    static func codeRejected(_ reason: String?) -> Bool {
        reason?.hasPrefix("MQTT CONNACK") == true
    }

    /// Before any printer reports, the menu bar and the panel speak for every printer at once. A rejected
    /// access code wins, since it needs the user and the panel offers Update Access Code… for it; one
    /// printer switched off must not show the moon over another that refuses its code.
    static func feedDownReason(focused: String?, all: [String]) -> String? {
        all.first(where: codeRejected) ?? focused ?? all.first
    }
}
