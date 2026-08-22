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

    static func activeFilament(_ printObj: [String: Any]) -> (type: String?, remain: Int?, tray: Int?, color: String?) {
        let ams = BambuJSON.dict(printObj["ams"]) ?? [:]
        var now = BambuJSON.intValue(ams["tray_now"])
        if now == nil { now = BambuJSON.intValue(ams["tray_tar"]) }
        guard let now, now != 255 else { return (nil, nil, nil, nil) }
        var tray: [String: Any]?
        if now == 254 {
            tray = BambuJSON.dict(printObj["vt_tray"])
        } else {
            tray = findAMSTray(ams, idx: now)
        }
        guard let tray else { return (nil, nil, nil, nil) }
        return (filamentName(tray), remainPercent(tray["remain"]), now, trayColorHex(tray))
    }

    /// Returns Left or Right for the nozzle that is down.
    /// Reads `device.extruder.state` bits 4 to 7 (0 is Right, 1 is Left). Nil on a single-nozzle printer.
    static func activeNozzle(_ printObj: [String: Any]) -> String? {
        let device = BambuJSON.dict(printObj["device"]) ?? [:]
        let extruder = BambuJSON.dict(device["extruder"]) ?? [:]
        guard let packed = BambuJSON.intValue(extruder["state"]) else { return nil }
        let count = packed & 0xF
        let infoCount = BambuJSON.array(extruder["info"])?.count ?? 0
        guard count >= 2 || infoCount >= 2 else { return nil }
        switch (packed >> 4) & 0xF {
        case 0: return "Right"
        case 1: return "Left"
        default: return nil
        }
    }

    /// MQTT `tray_color` or first `cols` entry, as RRGGBBAA. Nil if missing or fully transparent.
    static func trayColorHex(_ tray: [String: Any]) -> String? {
        if let hex = normalizeFilamentColor(trayString(tray, "tray_color")) { return hex }
        if let cols = BambuJSON.array(tray["cols"]) {
            for item in cols {
                if let hex = normalizeFilamentColor(BambuJSON.stringValue(item)) { return hex }
            }
        }
        return nil
    }

    static func normalizeFilamentColor(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.uppercased()
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 6 { s += "FF" }
        if s.hasSuffix("00") { return nil }
        return s
    }

    /// Product name when the printer sends one; otherwise `tray_type` (`PLA`).
    /// RFID official spools often leave `tray_sub_brands` empty and put the SKU in `tray_info_idx`.
    static func filamentName(_ tray: [String: Any]) -> String? {
        let type = trayString(tray, "tray_type") ?? trayString(tray, "type")
        let sub = trayString(tray, "tray_sub_brands")
        if let sub, sub != type { return dropBambuPrefix(sub) }
        if let idx = trayString(tray, "tray_info_idx"), let name = filamentByIdx[idx] {
            return name
        }
        if let sub { return dropBambuPrefix(sub) }
        return type
    }

    private static func trayString(_ tray: [String: Any], _ key: String) -> String? {
        guard let s = BambuJSON.stringValue(tray[key])?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty else { return nil }
        return s
    }

    private static func dropBambuPrefix(_ name: String) -> String {
        let prefix = "Bambu "
        guard name.hasPrefix(prefix) else { return name }
        let rest = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    // ponytail: static SKU table; add a row when a new Bambu id shows up as generic PLA.
    private static let filamentByIdx: [String: String] = [
        "GFA00": "PLA Basic",
        "GFA01": "PLA Matte",
        "GFA02": "PLA Metal",
        "GFA03": "PLA Impact",
        "GFA05": "PLA Silk",
        "GFA06": "PLA Silk+",
        "GFA07": "PLA Marble",
        "GFA08": "PLA Sparkle",
        "GFA09": "PLA Tough",
        "GFA10": "PLA Tough+",
        "GFA11": "PLA Aero",
        "GFA12": "PLA Glow",
        "GFA13": "PLA Dynamic",
        "GFA15": "PLA Galaxy",
        "GFA16": "PLA Wood",
        "GFA17": "PLA Translucent",
        "GFA18": "PLA Lite",
        "GFA19": "PLA Pure",
        "GFA50": "PLA-CF",
        "GFB00": "ABS",
        "GFB01": "ASA",
        "GFB02": "ASA-Aero",
        "GFB50": "ABS-GF",
        "GFB51": "ASA-CF",
        "GFB60": "PolyLite ABS",
        "GFB61": "PolyLite ASA",
        "GFB98": "Generic ASA",
        "GFB99": "Generic ABS",
        "GFC00": "PC",
        "GFC01": "PC FR",
        "GFC99": "Generic PC",
        "GFG00": "PETG Basic",
        "GFG01": "PETG Translucent",
        "GFG02": "PETG HF",
        "GFG50": "PETG-CF",
        "GFG60": "PolyLite PETG",
        "GFG96": "Generic PETG HF",
        "GFG97": "Generic PCTG",
        "GFG98": "Generic PETG-CF",
        "GFG99": "Generic PETG",
        "GFL00": "PolyLite PLA",
        "GFL01": "PolyTerra PLA",
        "GFL03": "eSUN PLA+",
        "GFL04": "Overture PLA",
        "GFL05": "Overture Matte PLA",
        "GFL06": "Fiberon PETG-ESD",
        "GFL50": "Fiberon PA6-CF",
        "GFL51": "Fiberon PA6-GF",
        "GFL52": "Fiberon PA12-CF",
        "GFL53": "Fiberon PA612-CF",
        "GFL54": "Fiberon PET-CF",
        "GFL55": "Fiberon PETG-rCF",
        "GFL95": "Generic PLA High Speed",
        "GFL96": "Generic PLA Silk",
        "GFL98": "Generic PLA-CF",
        "GFL99": "Generic PLA",
        "GFN03": "PA-CF",
        "GFN04": "PAHT-CF",
        "GFN05": "PA6-CF",
        "GFN06": "PPA-CF",
        "GFN08": "PA6-GF",
        "GFN96": "Generic PPA-GF",
        "GFN97": "Generic PPA-CF",
        "GFN98": "Generic PA-CF",
        "GFN99": "Generic PA",
        "GFP95": "Generic PP-GF",
        "GFP96": "Generic PP-CF",
        "GFP97": "Generic PP",
        "GFP98": "Generic PE-CF",
        "GFP99": "Generic PE",
        "GFR98": "Generic PHA",
        "GFR99": "Generic EVA",
        "GFS00": "Support W",
        "GFS01": "Support G",
        "GFS02": "Support for PLA",
        "GFS03": "Support for PA/PET",
        "GFS04": "PVA",
        "GFS05": "Support for PLA/PETG",
        "GFS06": "Support for ABS",
        "GFS97": "Generic BVOH",
        "GFS98": "Generic HIPS",
        "GFS99": "Generic PVA",
        "GFT01": "PET-CF",
        "GFT02": "PPS-CF",
        "GFT97": "Generic PPS",
        "GFT98": "Generic PPS-CF",
        "GFU00": "TPU 95A HF",
        "GFU01": "TPU 95A",
        "GFU02": "TPU for AMS",
        "GFU98": "Generic TPU for AMS",
        "GFU99": "Generic TPU",
    ]

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

    static func etaHM(
        state: String,
        remainingS: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch state {
        case "RUNNING", "PREPARE", "PAUSE": break
        default: return nil
        }
        guard let remainingS, remainingS > 0 else { return nil }
        let t = now.addingTimeInterval(TimeInterval(remainingS))
        let time = format(t, "HH:mm", calendar: calendar)
        if calendar.isDate(t, inSameDayAs: now) {
            return time
        }
        if let next = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(t, inSameDayAs: next)
        {
            return "\(time) tomorrow"
        }
        return "\(time) \(format(t, "EEE", calendar: calendar))"
    }

    private static func format(_ date: Date, _ dateFormat: String, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.dateFormat = dateFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.calendar = calendar
        return f.string(from: date)
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
            filamentColor: fil.color,
            nozzle: activeNozzle(printObj),
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

    static func fleetDoc(
        printers: [PrinterSettings],
        snapshots: [String: BambuSnapshot],
        focusId: String?
    ) -> PrintDoc {
        let rows: [Printer] = printers.map { p in
            if let snap = snapshots[p.serial] {
                return snap.printer()
            }
            return Printer(
                id: p.serial,
                name: p.displayName,
                state: "OFFLINE",
                percent: nil,
                remainingS: nil,
                job: nil,
                layer: nil,
                layerTotal: nil,
                eta: nil,
                filament: nil,
                filamentRemain: nil
            )
        }
        return PrintDoc(v: 1, updatedAt: nil, focusId: focusId, printers: rows)
    }
}
