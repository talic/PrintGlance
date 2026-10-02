import Foundation
import SwiftUI
@testable import PrintGlance

/// Printer rows in every state the card draws, for UI and layout tests.
@MainActor
enum Rows {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let fourTrays: [[String: Any]] = [
        ["id": "0", "tray_type": "PLA", "tray_info_idx": "GFA01", "remain": 80, "tray_color": "F5C6A0FF"],
        ["id": "1", "tray_type": "PLA", "tray_info_idx": "GFA00", "remain": 12, "tray_color": "000000FF"],
        ["id": "2"],
        ["id": "3", "tray_type": "PETG", "tray_info_idx": "GFG02", "remain": 40, "tray_color": "2850E0FF"],
    ]

    static let oneAMS: [String: Any] = ["ams": ["ams": [["id": "0", "humidity": "2", "tray": fourTrays]]]]

    /// Four AMS units, an AMS HT, and both external spools: the tallest card.
    static let fullAMS: [String: Any] = [
        "ams": ["ams": (0..<4).map { ["id": "\($0)", "humidity": "4", "tray": fourTrays] }
            + [["id": "128", "info": "4", "humidity": "3", "humidity_raw": "45", "tray": [fourTrays[0]]]]],
        "vir_slot": [
            ["id": "255", "tray_type": "TPU", "tray_info_idx": "GFU01", "remain": 30, "tray_color": "FF6600FF"],
            ["id": "254", "tray_type": "PLA", "tray_info_idx": "GFA00", "remain": 95, "tray_color": "FFFFFFFF"],
        ],
    ]

    static func printing(_ state: String = "RUNNING", ams: [String: Any] = oneAMS) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: state, percent: 52, job: "Benchy", jobId: "t1")
        p.remainingS = 84 * 60
        p.eta = "16:25"
        p.layer = 18
        p.layerTotal = 29
        p.filament = "PLA Matte"
        p.filamentRemain = 80
        p.filamentColor = "F5C6A0FF"
        p.trays = BambuPrint.trays(ams)
        p.amsUnits = BambuPrint.amsUnits(ams)
        return p
    }

    static func starting() -> Printer {
        var p = printing("PREPARE")
        p.percent = 0
        p.layer = 0
        p.stage = "Heating"
        p.nozzleTemp = Temp(current: 186, target: 220)
        p.bedTemp = Temp(current: 48, target: 60)
        return p
    }

    static func paused(hms: String? = "0700-2000-0002-0001") -> Printer {
        var p = printing("PAUSE")
        p.hmsCode = hms
        return p
    }

    static func failed() -> Printer {
        var p = printing("FAILED")
        p.percent = 37
        p.remainingS = nil
        p.eta = nil
        p.printError = "0300-806E"
        return p
    }

    static func finished() -> Printer {
        var p = idle()
        p.state = "FINISH"
        p.percent = 100
        p.job = "Benchy"
        p.jobId = "t1"
        return p
    }

    static func idle(_ ams: [String: Any] = oneAMS) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: "IDLE")
        p.trays = BambuPrint.trays(ams)
        p.amsUnits = BambuPrint.amsUnits(ams)
        return p
    }

    static func offline(was state: String, minutesAgo: Double = 20) -> Printer {
        var p = printing()
        p.state = "OFFLINE"
        p.lastState = state
        p.lastSeen = now - minutesAgo * 60
        return p
    }

    /// The card as the panel lays it out: header, then the printer's details.
    static func card(
        _ row: Printer,
        endedAt: Date? = nil,
        reason: String? = nil,
        onUpdateCode: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(headline: GlanceContent.headline(row), subtitle: GlanceContent.subtitle(row), state: row.state)
            PrinterDetail(row: row, endedAt: endedAt, now: now, disconnectReason: reason, onUpdateCode: onUpdateCode)
        }
        .padding(14)
        .frame(width: 248, alignment: .leading)
    }
}
