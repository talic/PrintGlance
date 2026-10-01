import AppKit
import SwiftUI
import XCTest
@testable import PrintGlance

/// Writes 2x PNGs of every card state, light and dark, when `PG_RENDER_DIR` is set.
/// Nothing is asserted: open the images and look. `make test` alone skips this.
@MainActor
final class RenderStatesTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testRenderPrinterDetail() throws {
        let dir = try renderDir()
        for (name, row, endedAt, reason) in Self.detailStates() {
            try write("detail-\(name)", card(row: row, endedAt: endedAt, reason: reason), to: dir)
        }
    }

    func testRenderStrip() throws {
        let dir = try renderDir()
        var strips: [(String, StripPresentation)] = [
            ("feed-down", GlanceContent.strip(.feedDown)),
            ("connecting", GlanceContent.strip(.connecting)),
            ("needs-setup", GlanceContent.strip(.needsSetup)),
        ]
        for (name, row, endedAt, _) in Self.detailStates() {
            strips.append((name, GlanceContent.strip(row: row, occupancyEndedAt: endedAt, now: Self.now)))
        }
        for (name, strip) in strips {
            try write(
                "strip-\(name)",
                StripLabel(strip: strip).padding(.horizontal, 8).padding(.vertical, 4),
                to: dir
            )
        }
    }

    private func card(row: Printer, endedAt: Date?, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                headline: GlanceContent.headline(row),
                subtitle: GlanceContent.subtitle(row),
                state: row.state
            )
            PrinterDetail(row: row, endedAt: endedAt, now: Self.now, disconnectReason: reason)
        }
        .padding(14)
        .frame(width: 248, alignment: .leading)
    }

    // MARK: - States

    private static func detailStates() -> [(String, Printer, Date?, String?)] {
        let printing = running("RUNNING")
        var dual = printing
        dual.nozzle = "Left"

        var starting = running("PREPARE")
        starting.percent = 0
        starting.layer = 0
        starting.stage = "Heating"

        var paused = running("PAUSE")
        paused.hmsCode = "0700-2000-0002-0001"
        paused.printError = "0700-8002"
        var pausedBare = running("PAUSE")
        pausedBare.hmsCode = nil

        var failed = running("FAILED")
        failed.percent = 37
        failed.remainingS = nil
        failed.eta = nil
        failed.hmsCode = "0300-0000-0100-0001"

        var finished = idle(oneAMS)
        finished.state = "FINISH"
        finished.percent = 100
        finished.job = "Benchy"
        finished.jobId = "t1"

        var offlinePrinting = running("RUNNING")
        offlinePrinting.state = "OFFLINE"
        offlinePrinting.lastState = "RUNNING"
        offlinePrinting.lastSeen = now - 20 * 60
        var offlineDue = offlinePrinting
        offlineDue.lastSeen = now - 3 * 3600
        var offlinePaused = offlinePrinting
        offlinePaused.lastState = "PAUSE"
        var offlineIdle = idle(oneAMS)
        offlineIdle.state = "OFFLINE"
        offlineIdle.lastState = "IDLE"
        offlineIdle.lastSeen = now - 26 * 3600
        let offlineNever = Printer(id: "x2d", name: "X2D", state: "OFFLINE")

        return [
            ("printing", printing, nil, nil),
            ("printing-dual", dual, nil, nil),
            ("starting", starting, nil, nil),
            ("paused-code", paused, nil, nil),
            ("paused-bare", pausedBare, nil, nil),
            ("failed-code", failed, nil, nil),
            ("finished-40m", finished, now - 40 * 60, nil),
            ("finished-unknown", finished, nil, nil),
            ("finished-2d", finished, now - 51 * 3600, nil),
            ("idle-one-ams", idle(oneAMS), nil, nil),
            ("idle-two-ams-ext", idle(twoAMSExternal), nil, nil),
            ("offline-was-printing", offlinePrinting, nil, "connect timed out"),
            ("offline-was-due", offlineDue, nil, "connect timed out"),
            ("offline-was-paused", offlinePaused, nil, "connect timed out"),
            ("offline-was-idle", offlineIdle, nil, "ECONNREFUSED"),
            ("offline-never", offlineNever, nil, "MQTT CONNACK 5"),
        ]
    }

    private static func running(_ state: String) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: state, percent: 52, job: "Benchy", jobId: "t1")
        p.remainingS = 84 * 60
        p.eta = "16:25"
        p.layer = 18
        p.layerTotal = 29
        p.filament = "PLA Matte"
        p.filamentRemain = 80
        p.filamentColor = "F5C6A0FF"
        p.trays = BambuPrint.trays(oneAMS)
        p.humidity = BambuPrint.amsHumidity(oneAMS)
        return p
    }

    private static func idle(_ printObj: [String: Any]) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: "IDLE")
        p.trays = BambuPrint.trays(printObj)
        p.humidity = BambuPrint.amsHumidity(printObj)
        return p
    }

    private static func unit(_ id: String, humidity: String, _ trays: [[String: Any]]) -> [String: Any] {
        ["id": id, "humidity": humidity, "tray": trays]
    }

    private static let fourTrays: [[String: Any]] = [
        ["id": "0", "tray_type": "PLA", "tray_info_idx": "GFA01", "remain": 80, "tray_color": "F5C6A0FF"],
        ["id": "1", "tray_type": "PLA", "tray_info_idx": "GFA00", "remain": 12, "tray_color": "000000FF"],
        ["id": "2"],
        ["id": "3", "tray_type": "PETG", "tray_info_idx": "GFG02", "remain": 40, "tray_color": "2850E0FF"],
    ]

    private static let oneAMS: [String: Any] = [
        "ams": ["ams": [unit("0", humidity: "2", fourTrays)]],
    ]

    private static let twoAMSExternal: [String: Any] = [
        "ams": ["ams": [
            unit("0", humidity: "2", fourTrays),
            unit("1", humidity: "4", [
                ["id": "0", "tray_type": "ABS", "remain": 90, "tray_color": "FFFFFFFF"],
                ["id": "1", "tray_type": "PLA", "tray_info_idx": "GFA05", "remain": 55, "tray_color": "C0C0C0FF"],
            ]),
        ]],
        "vt_tray": ["id": "254", "tray_type": "TPU", "tray_info_idx": "GFU01", "remain": -1, "tray_color": "FF6600FF"],
    ]

    // MARK: - Rendering

    private func renderDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PG_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PG_RENDER_DIR to write card renders")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, _ view: some View, to dir: URL) throws {
        for (suffix, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let host = NSHostingView(rootView: AnyView(
                view
                    .environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor))
            ))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
