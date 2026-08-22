import Foundation
import Security

enum AccessCodeStore {
    static let service = "local.PrintGlance.accessCode"

    static func get(_ serial: String, service: String = service) -> String? {
        guard !serial.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ serial: String, _ code: String, service: String = service) {
        guard !serial.isEmpty else { return }
        delete(serial, service: service)
        guard !code.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
            kSecValueData as String: Data(code.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ serial: String, service: String = service) {
        guard !serial.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

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
        return saved.hydratingCodes(from: d)
    }

    func save(to d: UserDefaults = .standard) {
        let useKeychain = d === UserDefaults.standard
        if useKeychain {
            let previous = (d.array(forKey: Self.printersKey) as? [[String: Any]] ?? [])
                .compactMap { $0["serial"] as? String }
            let keep = Set(printers.map(\.serial))
            for serial in previous where !keep.contains(serial) {
                AccessCodeStore.delete(serial)
            }
        }
        let arr: [[String: String]] = printers.map { p in
            if useKeychain {
                AccessCodeStore.set(p.serial, p.accessCode)
            }
            var row = [
                "ip": p.ip,
                "serial": p.serial,
                "name": p.name,
            ]
            if !useKeychain {
                row["accessCode"] = p.accessCode
            }
            return row
        }
        d.set(arr, forKey: Self.printersKey)
        d.set(focusId, forKey: Self.focusKey)
        if useKeychain {
            d.removeObject(forKey: Self.legacyCode)
        }
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
            .hydratingCodes(from: d)
    }

    /// UserDefaults.standard keeps the MQTT password in Keychain, not the plist.
    /// Suite defaults (tests) still store `accessCode` on the printer row.
    fileprivate func hydratingCodes(from d: UserDefaults) -> SavedPrinters {
        guard d === UserDefaults.standard else { return self }
        let printers = self.printers.map { p -> PrinterSettings in
            var p = p
            if p.accessCode.isEmpty {
                p.accessCode = AccessCodeStore.get(p.serial) ?? ""
            } else {
                AccessCodeStore.set(p.serial, p.accessCode)
            }
            return p
        }
        let next = SavedPrinters(printers: printers, focusId: focusId)
        if printers.contains(where: { !$0.accessCode.isEmpty }) {
            let raw = d.array(forKey: Self.printersKey) ?? []
            let plistHasCode = raw.contains { item in
                guard let dict = item as? [String: Any] else { return false }
                let code = dict["accessCode"] as? String ?? ""
                return !code.isEmpty
            }
            if plistHasCode || d.object(forKey: Self.legacyCode) != nil {
                next.save(to: d)
            }
        }
        return next
    }
}
