import Foundation

enum BambuJSON {
    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int:
            return n
        case let n as Int64:
            return Int(n)
        case let n as Double:
            return Int(n)
        case let n as NSNumber:
            return n.intValue
        case let s as String:
            return Int(s)
        default:
            return nil
        }
    }

    static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        return nil
    }

    static func dict(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }
}

enum BambuPrint {
    static let staleAfter: TimeInterval = 120
    static let knownStates: Set<String> = [
        "PREPARE", "RUNNING", "PAUSE", "FINISH", "FAILED", "IDLE", "OFFLINE",
    ]

    static func merge(_ dst: inout [String: Any], incoming: [String: Any]) {
        guard !incoming.isEmpty else { return }
        if jobChanged(dst, incoming) {
            dst.removeValue(forKey: "layer_num")
            dst.removeValue(forKey: "total_layer_num")
            dst.removeValue(forKey: "gcode_file")
        }
        for (k, v) in incoming {
            dst[k] = v
        }
    }

    private static func jobChanged(_ dst: [String: Any], _ incoming: [String: Any]) -> Bool {
        for key in ["task_id", "subtask_id", "subtask_name"] {
            guard incoming[key] != nil else { continue }
            let old = stringify(dst[key])
            let new = stringify(incoming[key])
            if old.isEmpty || new.isEmpty { continue }
            if old != new { return true }
        }
        return false
    }

    private static func stringify(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        return "\(any)"
    }

    static func humanGcodeStem(_ gcodeFile: Any?) -> String? {
        guard let raw = BambuJSON.stringValue(gcodeFile)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        let s = raw.replacingOccurrences(of: "\\", with: "/")
        let low = s.lowercased()
        if low.hasPrefix("cache/") || low.contains("/cache/") { return nil }
        var stem = s.split(separator: "/").last.map(String.init) ?? s
        for ext in [".gcode", ".3mf", ".gco"] where stem.lowercased().hasSuffix(ext) {
            stem = String(stem.dropLast(ext.count))
            break
        }
        if stem.count < 2 { return nil }
        if stem.range(of: "^[0-9a-fA-F]{8,}$", options: .regularExpression) != nil { return nil }
        if stem.range(of: "^\\d{6,}$", options: .regularExpression) != nil { return nil }
        return stem
    }

    static func stripProcessSuffix(_ name: String) -> String {
        let pattern = #"\s+\d+(\.\d+)?mm\b.*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return name
        }
        let range = NSRange(name.startIndex..., in: name)
        return re.stringByReplacingMatches(in: name, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func jobIdentity(_ printObj: [String: Any]) -> String? {
        let task = stringify(printObj["task_id"])
        if !task.isEmpty { return task }
        let sub = stringify(printObj["subtask_id"])
        return sub.isEmpty ? nil : sub
    }

    static func jobLabel(_ printObj: [String: Any]) -> String? {
        var label: String
        if let stem = humanGcodeStem(printObj["gcode_file"]) {
            label = stem
        } else {
            guard let raw = BambuJSON.stringValue(printObj["subtask_name"])?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let stripped = stripProcessSuffix(raw)
            label = stripped.isEmpty ? raw : stripped
        }
        if label.count > 40 {
            label = String(label.prefix(37)) + "..."
        }
        return label.isEmpty ? nil : label
    }

    /// Remaining filament percent. Values below 0 mean no sensor and become nil.
    static func remainPercent(_ raw: Any?) -> Int? {
        guard let r = BambuJSON.intValue(raw), r >= 0 else { return nil }
        return min(100, r)
    }

    static func taskId(_ printObj: [String: Any]) -> String? {
        jobIdentity(printObj)
    }

    static func activeFilament(_ printObj: [String: Any]) -> (type: String?, remain: Int?, tray: Int?) {
        let ams = BambuJSON.dict(printObj["ams"]) ?? [:]
        var now = BambuJSON.intValue(ams["tray_now"])
        if now == nil { now = BambuJSON.intValue(ams["tray_tar"]) }
        guard let now, now != 255 else { return (nil, nil, nil) }
        var tray: [String: Any]?
        if now == 254 {
            tray = BambuJSON.dict(printObj["vt_tray"])
        } else {
            tray = findAMSTray(ams, idx: now)
        }
        guard let tray else { return (nil, nil, nil) }
        var fil: String?
        if let raw = BambuJSON.stringValue(tray["tray_type"]) ?? BambuJSON.stringValue(tray["type"]) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { fil = String(t.prefix(8)) }
        }
        return (fil, remainPercent(tray["remain"]), now)
    }

    private static func findAMSTray(_ ams: [String: Any], idx: Int) -> [String: Any]? {
        guard let units = BambuJSON.array(ams["ams"]) else { return nil }
        for unit in units {
            guard let unit = BambuJSON.dict(unit), let trays = BambuJSON.array(unit["tray"]) else {
                continue
            }
            for tray in trays {
                guard let tray = BambuJSON.dict(tray) else { continue }
                if BambuJSON.intValue(tray["id"]) == idx { return tray }
            }
        }
        return nil
    }

    static func etaHM(state: String, remainingS: Int?) -> String? {
        switch state {
        case "RUNNING", "PREPARE", "PAUSE": break
        default: return nil
        }
        guard let remainingS, remainingS > 0 else { return nil }
        let t = Date().addingTimeInterval(TimeInterval(remainingS))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: t)
    }

    static func row(
        id: String,
        name: String,
        printObj: [String: Any],
        online: Bool
    ) -> Printer {
        let raw = (BambuJSON.stringValue(printObj["gcode_state"]) ?? "").uppercased()
        let state: String
        if !online {
            state = "OFFLINE"
        } else if raw.isEmpty {
            state = "OFFLINE"
        } else {
            state = raw
        }
        var percent = BambuJSON.intValue(printObj["mc_percent"])
        if let p = percent { percent = min(100, max(0, p)) }
        var remainingS: Int?
        if let minutes = BambuJSON.intValue(printObj["mc_remaining_time"]) {
            remainingS = max(0, minutes * 60)
        }
        var layer: Int?
        var layerTotal: Int?
        if printObj["layer_num"] != nil { layer = BambuJSON.intValue(printObj["layer_num"]) }
        if printObj["total_layer_num"] != nil {
            layerTotal = BambuJSON.intValue(printObj["total_layer_num"])
        }
        let fil = activeFilament(printObj)
        return Printer(
            id: id,
            name: name,
            state: state,
            percent: percent,
            remainingS: remainingS,
            job: jobLabel(printObj),
            layer: layer,
            layerTotal: layerTotal,
            eta: etaHM(state: state, remainingS: remainingS),
            filament: fil.type,
            filamentRemain: fil.remain,
            jobId: jobIdentity(printObj)
        )
    }
}

final class BambuSnapshot {
    let printerID: String
    var name: String
    private(set) var printObj: [String: Any] = [:]
    private var lastReport: Date?
    private var connected = false

    init(printerID: String, name: String) {
        self.printerID = printerID
        self.name = name
    }

    func markConnected(_ ok: Bool) {
        connected = ok
    }

    func ingest(_ payload: [String: Any]) {
        guard let incoming = BambuJSON.dict(payload["print"]), !incoming.isEmpty else { return }
        BambuPrint.merge(&printObj, incoming: incoming)
        lastReport = Date()
        connected = true
    }

    var hasReport: Bool { lastReport != nil }

    var isOnline: Bool {
        guard connected, let lastReport else { return false }
        return Date().timeIntervalSince(lastReport) < BambuPrint.staleAfter
    }

    func printer() -> Printer {
        BambuPrint.row(id: printerID, name: name.isEmpty ? "Printer" : name, printObj: printObj, online: isOnline)
    }

    func doc() -> PrintDoc {
        let row = printer()
        return PrintDoc(v: 1, updatedAt: nil, focusId: row.id, printers: [row])
    }
}
