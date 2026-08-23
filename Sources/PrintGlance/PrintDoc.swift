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
    /// AMS humidity index 1–5 when the unit sends it.
    var humidity: Int? = nil
    /// First HMS code as AAAA-BBBB-CCCC-DDDD.
    var hmsCode: String? = nil
}

enum FeedResult: Equatable, Sendable {
    case doc(PrintDoc)
    case feedDown
    case unauthorized
    case http(Int)
    case invalid
    case needsSetup
    case connecting
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
