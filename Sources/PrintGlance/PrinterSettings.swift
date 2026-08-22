import Foundation

struct PrinterSettings: Equatable {
    var ip: String
    var serial: String
    var accessCode: String
    var name: String

    var isComplete: Bool {
        !ip.isEmpty && !serial.isEmpty && !accessCode.isEmpty
    }

    var displayName: String {
        name.isEmpty ? "Printer" : name
    }

    static let empty = PrinterSettings(ip: "", serial: "", accessCode: "", name: "")

    var trimmed: PrinterSettings {
        PrinterSettings(
            ip: ip.trimmingCharacters(in: .whitespacesAndNewlines),
            serial: serial.trimmingCharacters(in: .whitespacesAndNewlines),
            accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct SavedPrinters: Equatable {
    var printers: [PrinterSettings]
    var focusId: String?

    /// ponytail: cap 4; a farm dashboard is the upgrade if anyone outgrows a handful.
    static let maxCount = 4
    static let empty = SavedPrinters(printers: [], focusId: nil)

    static let printersKey = "printers"
    static let focusKey = "printerFocusId"
    static let legacyIP = "printerIP"
    static let legacySerial = "printerSerial"
    static let legacyCode = "printerAccessCode"
    static let legacyName = "printerName"

    var isComplete: Bool {
        printers.contains { $0.isComplete }
    }

    var canAdd: Bool {
        printers.count < Self.maxCount
    }

    static func load(from d: UserDefaults = .standard) -> SavedPrinters {
        if d.object(forKey: printersKey) != nil {
            return decode(from: d)
        }
        let legacy = PrinterSettings(
            ip: d.string(forKey: legacyIP) ?? "",
            serial: d.string(forKey: legacySerial) ?? "",
            accessCode: d.string(forKey: legacyCode) ?? "",
            name: d.string(forKey: legacyName) ?? ""
        ).trimmed
        let hasLegacy = !legacy.ip.isEmpty
            || !legacy.serial.isEmpty
            || !legacy.accessCode.isEmpty
            || !legacy.name.isEmpty
        let saved = SavedPrinters(printers: hasLegacy ? [legacy] : [], focusId: nil)
        if hasLegacy {
            saved.save(to: d)
        }
        return saved
    }

    func save(to d: UserDefaults = .standard) {
        let arr: [[String: String]] = printers.map {
            [
                "ip": $0.ip,
                "serial": $0.serial,
                "accessCode": $0.accessCode,
                "name": $0.name,
            ]
        }
        d.set(arr, forKey: Self.printersKey)
        d.set(focusId, forKey: Self.focusKey)
    }

    func adding(_ printer: PrinterSettings) -> SavedPrinters {
        let next = printer.trimmed
        var printers = self.printers
        if let i = printers.firstIndex(where: { $0.serial == next.serial }) {
            printers[i] = next
        } else if printers.count < Self.maxCount {
            printers.append(next)
        }
        return SavedPrinters(printers: printers, focusId: focusId)
    }

    func replacing(_ printer: PrinterSettings, serial: String) -> SavedPrinters {
        let next = printer.trimmed
        var printers = self.printers
        guard let i = printers.firstIndex(where: { $0.serial == serial }) else {
            return adding(next)
        }
        printers[i] = next
        let focus = focusId == serial ? next.serial : focusId
        return SavedPrinters(printers: printers, focusId: focus)
    }

    func removing(serial: String) -> SavedPrinters {
        SavedPrinters(
            printers: printers.filter { $0.serial != serial },
            focusId: focusId == serial ? nil : focusId
        )
    }

    func focusing(_ id: String) -> SavedPrinters {
        SavedPrinters(printers: printers, focusId: id)
    }

    private static func decode(from d: UserDefaults) -> SavedPrinters {
        let raw = d.array(forKey: printersKey) ?? []
        let printers: [PrinterSettings] = raw.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return PrinterSettings(
                ip: dict["ip"] as? String ?? "",
                serial: dict["serial"] as? String ?? "",
                accessCode: dict["accessCode"] as? String ?? "",
                name: dict["name"] as? String ?? ""
            )
        }
        return SavedPrinters(printers: printers, focusId: d.string(forKey: focusKey))
    }
}
