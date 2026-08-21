import Foundation

struct PrinterSettings: Equatable {
    var ip: String
    var serial: String
    var accessCode: String
    var name: String

    var isComplete: Bool {
        !ip.isEmpty && !serial.isEmpty && !accessCode.isEmpty
    }

    static let empty = PrinterSettings(ip: "", serial: "", accessCode: "", name: "")

    static func load() -> PrinterSettings {
        let d = UserDefaults.standard
        return PrinterSettings(
            ip: d.string(forKey: "printerIP") ?? "",
            serial: d.string(forKey: "printerSerial") ?? "",
            accessCode: d.string(forKey: "printerAccessCode") ?? "",
            name: d.string(forKey: "printerName") ?? ""
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(ip.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "printerIP")
        d.set(serial.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "printerSerial")
        d.set(accessCode.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "printerAccessCode")
        d.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "printerName")
    }

    var trimmed: PrinterSettings {
        PrinterSettings(
            ip: ip.trimmingCharacters(in: .whitespacesAndNewlines),
            serial: serial.trimmingCharacters(in: .whitespacesAndNewlines),
            accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
