import Foundation

enum BambuJSON {
    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int:
            return n
        case let n as Int64:
            return Int(n)
        case let n as Double:
            return Int(exactly: n.rounded(.towardZero))
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
    static let offlineGrace: TimeInterval = 30

    static func merge(_ dst: inout [String: Any], incoming: [String: Any]) {
        guard !incoming.isEmpty else { return }
        if jobChanged(dst, incoming) {
            dst.removeValue(forKey: "layer_num")
            dst.removeValue(forKey: "total_layer_num")
            dst.removeValue(forKey: "gcode_file")
        }
        mergeObjects(&dst, incoming)
    }

    /// Like Bambu Studio's json_diff: nested objects merge key by key, so a report that sends only
    /// `device.extruder` keeps `device.bed`. Arrays and values are replaced whole.
    private static func mergeObjects(_ dst: inout [String: Any], _ incoming: [String: Any]) {
        for (k, v) in incoming {
            if let new = v as? [String: Any], var old = dst[k] as? [String: Any] {
                mergeObjects(&old, new)
                dst[k] = old
            } else {
                dst[k] = v
            }
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
        // Sliced files are "Benchy.gcode.3mf", so strip every known extension, not just the last.
        while let ext = [".gcode", ".3mf", ".gco"].first(where: { stem.lowercased().hasSuffix($0) }) {
            stem = String(stem.dropLast(ext.count))
        }
        if stem.count < 2 { return nil }
        if stem.range(of: "^[0-9a-fA-F]{8,}$", options: .regularExpression) != nil { return nil }
        if stem.range(of: "^\\d{6,}$", options: .regularExpression) != nil { return nil }
        return stem
    }

    /// Cuts a slicer suffix like " 0.16mm layer, 2 walls, 10% infill". Only layer heights (under 1 mm)
    /// count, so a size in the name, like "Spacer 20mm", stays.
    static func stripProcessSuffix(_ name: String) -> String {
        let pattern = #"\s+0?\.\d+\s*mm\b.*"#
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

    /// Returns Left or Right for the nozzle that is down. Nil on a single-nozzle printer.
    static func activeNozzle(_ printObj: [String: Any]) -> String? {
        switch extruders(printObj)?.active {
        case 0: return "Right"
        case 1: return "Left"
        default: return nil
        }
    }

    /// Dual-nozzle printers: the nozzle that is down (`device.extruder.state` bits 4 to 7, bits 0 to 3
    /// count the nozzles) and each nozzle's `device.extruder.info` entry. Nil with one nozzle.
    private static func extruders(_ printObj: [String: Any]) -> (active: Int, info: [[String: Any]])? {
        let device = BambuJSON.dict(printObj["device"]) ?? [:]
        let extruder = BambuJSON.dict(device["extruder"]) ?? [:]
        guard let packed = BambuJSON.intValue(extruder["state"]) else { return nil }
        let info = (BambuJSON.array(extruder["info"]) ?? []).compactMap(BambuJSON.dict)
        guard packed & 0xF >= 2 || info.count >= 2 else { return nil }
        return ((packed >> 4) & 0xF, info)
    }

    /// Newer printers pack a heater as `target << 16 | current` in whole °C (Bambu Studio, DevUtil.cpp).
    static func packedTemp(_ raw: Any?) -> Temp? {
        guard let v = BambuJSON.intValue(raw), v >= 0 else { return nil }
        return Temp(current: v & 0xFFFF, target: (v >> 16) & 0xFFFF)
    }

    /// Top-level fields are numbers, often 1/32 °C steps on A1 and P1; cut to whole degrees like Bambu Studio.
    private static func temp(_ current: Any?, _ target: Any?) -> Temp? {
        guard let current = BambuJSON.intValue(current) else { return nil }
        return Temp(current: current, target: max(0, BambuJSON.intValue(target) ?? 0))
    }

    /// The nozzle in use. Dual-nozzle printers report each nozzle under `device.extruder.info`, matched by
    /// `id`; their top-level `nozzle_temper` follows either nozzle, so Bambu Studio ignores it there.
    static func nozzleTemp(_ printObj: [String: Any]) -> Temp? {
        if let dual = extruders(printObj) {
            return dual.info.first { BambuJSON.intValue($0["id"]) == dual.active }.flatMap { packedTemp($0["temp"]) }
        }
        return temp(printObj["nozzle_temper"], printObj["nozzle_target_temper"])
    }

    static func bedTemp(_ printObj: [String: Any]) -> Temp? {
        let device = BambuJSON.dict(printObj["device"]) ?? [:]
        let info = BambuJSON.dict(BambuJSON.dict(device["bed"])?["info"])
        return packedTemp(info?["temp"]) ?? packedTemp(device["bed_temp"])
            ?? temp(printObj["bed_temper"], printObj["bed_target_temper"])
    }

    /// `device.ctc` on newer firmware. Printers without a chamber sensor send a placeholder 5 with no target.
    static func chamberTemp(_ printObj: [String: Any]) -> Temp? {
        let device = BambuJSON.dict(printObj["device"]) ?? [:]
        let info = BambuJSON.dict(BambuJSON.dict(device["ctc"])?["info"])
        return packedTemp(info?["temp"]) ?? temp(printObj["chamber_temper"], printObj["ctt"])
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
        // tray_now is global (AMS1 = 0–3, AMS2 = 4–7). Each unit's tray ids are 0–3.
        if let hit = matchAMSTray(units, unitId: idx / 4, trayId: idx % 4) {
            return hit
        }
        return matchAMSTray(units, unitId: nil, trayId: idx)
    }

    private static func matchAMSTray(_ units: [Any], unitId: Int?, trayId: Int) -> [String: Any]? {
        for (i, unit) in units.enumerated() {
            guard let unit = BambuJSON.dict(unit), let trays = BambuJSON.array(unit["tray"]) else {
                continue
            }
            if let unitId {
                let uid = BambuJSON.intValue(unit["id"]) ?? i
                if uid != unitId { continue }
            }
            for tray in trays {
                guard let tray = BambuJSON.dict(tray) else { continue }
                if BambuJSON.intValue(tray["id"]) == trayId { return tray }
            }
        }
        return nil
    }

    static func etaHM(
        state: String,
        remainingS: Int?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        switch state {
        case "RUNNING", "PREPARE", "PAUSE": break
        default: return nil
        }
        guard let remainingS, remainingS > 0 else { return nil }
        let t = now.addingTimeInterval(TimeInterval(remainingS))
        return GlanceContent.dayTime(t, now: now, calendar: calendar, locale: locale)
    }

    static func row(
        id: String,
        name: String,
        printObj: [String: Any],
        online: Bool,
        lastReportAt: Date? = nil
    ) -> Printer {
        let raw = (BambuJSON.stringValue(printObj["gcode_state"]) ?? "").uppercased()
        let state: String
        if !online {
            state = "OFFLINE"
        } else if raw.isEmpty {
            state = "OFFLINE"
        } else if isStartSequence(raw: raw, printObj: printObj) {
            state = "PREPARE"
        } else {
            state = raw
        }
        var percent = BambuJSON.intValue(printObj["mc_percent"])
        if let p = percent { percent = min(100, max(0, p)) }
        var remainingS: Int?
        if let minutes = BambuJSON.intValue(printObj["mc_remaining_time"]) {
            remainingS = min(max(minutes, 0), 43_200) * 60
        }
        var layer: Int?
        var layerTotal: Int?
        if printObj["layer_num"] != nil { layer = BambuJSON.intValue(printObj["layer_num"]) }
        if printObj["total_layer_num"] != nil {
            layerTotal = BambuJSON.intValue(printObj["total_layer_num"])
        }
        let fil = activeFilament(printObj)
        var row = Printer(
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
            jobId: jobIdentity(printObj),
            stage: stageLabel(state: state, printObj: printObj),
            trays: trays(printObj),
            humidity: amsHumidity(printObj),
            amsUnits: { let u = amsUnits(printObj); return u.isEmpty ? nil : u }(),
            hmsCode: firstHMSCode(printObj),
            printError: printErrorCode(printObj["print_error"])
        )
        if !online, let lastReportAt {
            row.lastSeen = lastReportAt
            row.lastState = raw.isEmpty ? nil : raw
        }
        if state == "PREPARE" {
            row.nozzleTemp = nozzleTemp(printObj)
            row.bedTemp = bedTemp(printObj)
            row.chamberTemp = chamberTemp(printObj)
        }
        return row
    }

    /// Printers heat, level and calibrate under RUNNING with the layer still 0 and `stg_cur` naming
    /// the stage (0 is printing). PREPARE itself only covers getting the file (Bambu Studio's
    /// StatusPanel). Both are Starting here. A stage after layer 0, like a filament change, is printing.
    static func isStartSequence(raw: String, printObj: [String: Any]) -> Bool {
        guard raw == "RUNNING", let stage = BambuJSON.intValue(printObj["stg_cur"]), stage != 0 else { return false }
        return (BambuJSON.intValue(printObj["layer_num"]) ?? 0) == 0
    }

    static func stageLabel(state: String, printObj: [String: Any]) -> String? {
        guard state.uppercased() == "PREPARE" else { return nil }
        guard let stg = BambuJSON.intValue(printObj["stg_cur"]) else { return "Starting" }
        switch stg {
        case 2, 7, 15, 49, 54, 63: return "Heating"
        case 1, 9, 40, 47, 48, 57: return "Leveling"
        case 4, 24, 77: return "Loading filament"
        case 22: return "Unloading filament"
        case 3, 8, 12, 18, 19, 25, 37, 39, 51: return "Calibrating"
        case 14: return "Cleaning nozzle"
        case 13: return "Homing"
        default: return "Starting"
        }
    }

    /// Bambu Studio's names (GUI_App.cpp, transition_tridid): unit 0 is A, unit 1 is B;
    /// AMS HT units start at id 128 and are HT-A, HT-B.
    static func unitLabel(_ uid: Int) -> String {
        uid >= 128 ? "HT-\(letter(uid - 128))" : letter(uid)
    }

    private static func letter(_ i: Int) -> String {
        guard (0..<26).contains(i), let u = UnicodeScalar(65 + i) else { return "\(i)" }
        return String(Character(u))
    }

    static func trays(_ printObj: [String: Any]) -> [AMSTray] {
        var out: [AMSTray] = []
        let ams = BambuJSON.dict(printObj["ams"]) ?? [:]
        for (ui, unitAny) in (BambuJSON.array(ams["ams"]) ?? []).enumerated() {
            guard let unit = BambuJSON.dict(unitAny),
                  let trays = BambuJSON.array(unit["tray"]) else { continue }
            let uid = BambuJSON.intValue(unit["id"]) ?? ui
            let unitName = unitLabel(uid)
            for trayAny in trays {
                guard let tray = BambuJSON.dict(trayAny), var t = loadedTray(tray) else { continue }
                let tid = BambuJSON.intValue(tray["id"]) ?? 0
                // An HT unit has one slot and goes by the unit's name.
                let ht = uid >= 128
                t.id = ht ? "\(uid)" : "\(uid &* 4 &+ tid)"
                t.label = ht ? unitName : "\(unitName)\(tid &+ 1)"
                t.unit = unitName
                out.append(t)
            }
        }
        // Dual-nozzle printers send `vir_slot` (255 right, 254 left); others send `vt_tray` (DeviceManager.cpp).
        var externals = (BambuJSON.array(printObj["vir_slot"]) ?? []).compactMap(BambuJSON.dict)
        if externals.isEmpty, let vt = BambuJSON.dict(printObj["vt_tray"]) {
            externals = [vt]
        }
        for tray in externals {
            guard var t = loadedTray(tray) else { continue }
            let id = BambuJSON.intValue(tray["id"]) ?? 254
            t.id = "\(id)"
            switch (externals.count, id) {
            case (2..., 254): t.label = "External L"
            case (2..., 255): t.label = "External R"
            default: t.label = "External"
            }
            out.append(t)
        }
        return out
    }

    /// Nil for an empty slot.
    private static func loadedTray(_ tray: [String: Any]) -> AMSTray? {
        let name = filamentName(tray)
        let remain = remainPercent(tray["remain"])
        let color = trayColorHex(tray)
        if name == nil, remain == nil, color == nil { return nil }
        return AMSTray(id: "", name: name, remain: remain, color: color)
    }

    /// Bambu Studio shows a percent only for AMS 2 Pro and AMS HT (`info` type 3 and 4, DevFilaSystem.h).
    static func amsUnits(_ printObj: [String: Any]) -> [AMSUnit] {
        let ams = BambuJSON.dict(printObj["ams"]) ?? [:]
        return (BambuJSON.array(ams["ams"]) ?? []).enumerated().compactMap { ui, unitAny in
            guard let unit = BambuJSON.dict(unitAny) else { return nil }
            let uid = BambuJSON.intValue(unit["id"]) ?? ui
            let type = BambuJSON.stringValue(unit["info"]).flatMap { Int($0, radix: 16) }.map { $0 & 0xF }
                ?? (uid >= 128 ? 4 : 1)
            let level = BambuJSON.intValue(unit["humidity"]).flatMap { (1...5).contains($0) ? $0 : nil }
            let raw = BambuJSON.intValue(unit["humidity_raw"]).flatMap { (1...100).contains($0) ? $0 : nil }
            return AMSUnit(
                id: unitLabel(uid),
                humidityLevel: level,
                humidityPercent: [3, 4].contains(type) ? raw : nil
            )
        }
    }

    static func amsHumidity(_ printObj: [String: Any]) -> Int? {
        let ams = BambuJSON.dict(printObj["ams"]) ?? [:]
        guard let units = BambuJSON.array(ams["ams"]) else { return nil }
        for unitAny in units {
            guard let unit = BambuJSON.dict(unitAny),
                  let h = BambuJSON.intValue(unit["humidity"]),
                  (1...5).contains(h) else { continue }
            return h
        }
        return nil
    }

    /// Bambu Studio formats `print_error` as `%08X` with a dash after four digits (DeviceManager.cpp, get_error_code_str).
    static func printErrorCode(_ raw: Any?) -> String? {
        guard let n = BambuJSON.intValue(raw), n > 0 else { return nil }
        var hex = String(format: "%08X", UInt32(truncatingIfNeeded: n))
        hex.insert("-", at: hex.index(hex.startIndex, offsetBy: 4))
        return hex
    }

    static func firstHMSCode(_ printObj: [String: Any]) -> String? {
        guard let items = BambuJSON.array(printObj["hms"]) else { return nil }
        for item in items {
            guard let d = BambuJSON.dict(item) else { continue }
            let attrN = BambuJSON.intValue(d["attr"]) ?? 0
            let codeN = BambuJSON.intValue(d["code"]) ?? 0
            if attrN == 0, codeN == 0 { continue }
            let attr = UInt32(truncatingIfNeeded: attrN)
            let code = UInt32(truncatingIfNeeded: codeN)
            return String(
                format: "%04X-%04X-%04X-%04X",
                attr >> 16,
                attr & 0xFFFF,
                code >> 16,
                code & 0xFFFF
            )
        }
        return nil
    }
}

final class BambuSnapshot {
    let printerID: String
    var name: String
    private(set) var printObj: [String: Any] = [:]
    private(set) var lastReportAt: Date?
    /// Online while `now` is before this. Nil until the first report.
    /// `.distantFuture` means frozen online while the Mac sleeps.
    private var trustedUntil: Date?

    init(printerID: String, name: String) {
        self.printerID = printerID
        self.name = name
    }

    func ingest(_ payload: [String: Any], now: Date = Date()) {
        guard let incoming = BambuJSON.dict(payload["print"]), !incoming.isEmpty else { return }
        BambuPrint.merge(&printObj, incoming: incoming)
        lastReportAt = now
        trustedUntil = now + BambuPrint.staleAfter
    }

    /// Stays online for `offlineGrace` unless a report arrives first. Also ends a sleep freeze.
    func connectionLost(now: Date = Date()) {
        guard let trustedUntil else { return }
        self.trustedUntil = min(trustedUntil, now + BambuPrint.offlineGrace)
    }

    func willSleep(now: Date = Date()) {
        if isOnline(now: now) { trustedUntil = .distantFuture }
    }

    func didWake(now: Date = Date()) {
        if trustedUntil == .distantFuture { trustedUntil = now + BambuPrint.offlineGrace }
    }

    var hasReport: Bool { trustedUntil != nil }

    func isOnline(now: Date = Date()) -> Bool {
        guard let trustedUntil else { return false }
        return now < trustedUntil
    }

    func printer() -> Printer {
        BambuPrint.row(
            id: printerID,
            name: name.isEmpty ? "Printer" : name,
            printObj: printObj,
            online: isOnline(),
            lastReportAt: lastReportAt
        )
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
