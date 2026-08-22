import Foundation

/// One low-filament notice per printer, tray, and task while starting or printing.
struct FilamentAlert {
    static let thresholdPercent = 20

    struct Notice: Equatable, Sendable {
        var title: String
        var body: String
        var identifier: String
    }

    private var fired: Set<String> = []

    mutating func consider(
        serial: String,
        name: String,
        state: String,
        filament: String?,
        tray: Int?,
        remain: Int?,
        taskId: String?
    ) -> Notice? {
        switch state.uppercased() {
        case "RUNNING", "PREPARE":
            break
        default:
            return nil
        }
        guard let tray, let remain, remain < Self.thresholdPercent else { return nil }
        let task = taskId ?? ""
        let key = "\(serial)|\(tray)|\(task)"
        if fired.contains(key) { return nil }
        fired.insert(key)
        let trimmed = filament?.trimmingCharacters(in: .whitespaces) ?? ""
        let material = trimmed.isEmpty ? "filament" : trimmed
        let who = name.isEmpty ? "Printer" : name
        return Notice(
            title: "Low filament",
            body: "\(who) is using \(material) at \(remain)%.",
            identifier: "filament.\(key)"
        )
    }
}
