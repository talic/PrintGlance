import Foundation

struct PrintDoc: Codable, Equatable, Sendable {
    var v: Int
    var updatedAt: String?
    var focusId: String?
    var printers: [Printer]

    static func == (lhs: PrintDoc, rhs: PrintDoc) -> Bool {
        lhs.v == rhs.v && lhs.focusId == rhs.focusId && lhs.printers == rhs.printers
    }

    func focusRow() -> Printer? {
        if let id = focusId, let row = printers.first(where: { $0.id == id }) {
            return row
        }
        let active = printers.first {
            switch $0.state.uppercased() {
            case "RUNNING", "PREPARE": return true
            default: return false
            }
        }
        return active
            ?? printers.first { $0.state.uppercased() == "PAUSE" }
            ?? printers.first
    }
}

struct AMSTray: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String?
    var remain: Int?
    var color: String?
    /// The printer's name for the slot: A1…D4, HT-A, External, External L/R.
    var label: String? = nil
    /// `AMSUnit.id` of the unit holding this tray. Nil for an external spool.
    var unit: String? = nil
}

struct AMSUnit: Codable, Equatable, Sendable {
    /// A, B, … or HT-A for an AMS HT.
    var id: String
    /// 1 (wet) to 5 (dry).
    var humidityLevel: Int? = nil
    /// Percent, from AMS 2 Pro and AMS HT.
    var humidityPercent: Int? = nil
}

struct Printer: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var state: String
    var percent: Int?
    var remainingS: Int?
    var job: String?
    var layer: Int?
    var layerTotal: Int?
    var eta: String?
    var filament: String?
    var filamentRemain: Int?
    /// AMS `tray_color` as RRGGBBAA. Nil when the printer sends none.
    var filamentColor: String? = nil
    /// Dual-nozzle printers: Left or Right. Nil when the printer has one nozzle or does not send it.
    var nozzle: String? = nil
    /// MQTT `task_id`, or `subtask_id` when `task_id` is missing. Not the display job label.
    var jobId: String? = nil
    /// PREPARE stage word. Nil when not preparing or the printer sent none.
    var stage: String? = nil
    var trays: [AMSTray]? = nil
    /// First AMS unit's humidity index 1–5. Kept for the feed format; the card reads `amsUnits`.
    var humidity: Int? = nil
    var amsUnits: [AMSUnit]? = nil
    /// First HMS code as AAAA-BBBB-CCCC-DDDD.
    var hmsCode: String? = nil
    /// Non-zero `print_error` as AAAA-BBBB, the form Bambu Studio shows.
    var printError: String? = nil
    /// Offline only: when the last report arrived. Nil while online so rows stay equal between messages.
    var lastSeen: Date? = nil
    /// Offline only: `gcode_state` from the last report.
    var lastState: String? = nil
}

enum FeedResult: Equatable, Sendable {
    case doc(PrintDoc)
    case feedDown
    case needsSetup
    case connecting
}
