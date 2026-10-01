import Foundation

struct PrintDoc: Codable, Equatable, Sendable {
    var v: Int
    var updatedAt: String?
    var focusId: String?
    var printers: [Printer]

    static func == (lhs: PrintDoc, rhs: PrintDoc) -> Bool {
        lhs.v == rhs.v && lhs.focusId == rhs.focusId && lhs.printers == rhs.printers
    }

    /// The printer that needs you: Paused, then Printing or Starting (finishing soonest),
    /// then Failed, then Finished, then the rest. Focus breaks ties, then saved order.
    func displayRow() -> Printer? {
        func key(_ i: Int, _ p: Printer) -> (Int, Int, Int, Int) {
            let tier: Int
            switch p.state.uppercased() {
            case "PAUSE": tier = 0
            case "RUNNING", "PREPARE": tier = 1
            case "FAILED": tier = 2
            case "FINISH": tier = 3
            default: tier = 4
            }
            let soonest = tier == 1 ? p.remainingS ?? .max : 0
            return (tier, p.id == focusId ? 0 : 1, soonest, i)
        }
        return printers.enumerated().min { key($0.offset, $0.element) < key($1.offset, $1.element) }?.element
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

/// A heater in whole °C, cut off like Bambu Studio shows it. Target 0 means it isn't heating.
struct Temp: Codable, Equatable, Sendable {
    var current: Int
    var target: Int
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
    /// Starting only, so rows stay equal between reports while printing. The nozzle in use.
    var nozzleTemp: Temp? = nil
    var bedTemp: Temp? = nil
    var chamberTemp: Temp? = nil
    /// Printing or paused: where a spool should run out before the end.
    var runout: Runout? = nil
}

enum FeedResult: Equatable, Sendable {
    case doc(PrintDoc)
    case feedDown
    case needsSetup
    case connecting
}
