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
        let rejected = Printer(id: "x2d", name: "X2D", state: "OFFLINE")
        try write("detail-offline-code-rejected", card(row: rejected, endedAt: nil, reason: "MQTT CONNACK 5", onUpdateCode: {}), to: dir)
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

    func testRenderPrinterList() throws {
        let dir = try renderDir()
        var paused = Self.running("PAUSE")
        paused.id = "p1s"
        paused.name = "P1S"
        paused.hmsCode = "0700-2000-0002-0001"
        var idle = Self.idle(Self.oneAMS)
        idle.id = "a1"
        idle.name = "A1 mini"
        let printers = [Self.running("RUNNING"), paused, idle]
        for (name, shown) in [("paused-shown", "p1s"), ("printing-shown", "x2d")] {
            let row = try XCTUnwrap(printers.first { $0.id == shown })
            let view = VStack(alignment: .leading, spacing: 12) {
                CardHeader(headline: GlanceContent.headline(row), subtitle: GlanceContent.subtitle(row), state: row.state)
                PrinterDetail(row: row, endedAt: nil, now: Self.now, disconnectReason: nil)
                Divider()
                PrinterList(printers: printers, shownId: row.id, onSelect: { _ in }, onEdit: { _ in }, onRemove: { _ in })
            }
            .padding(14)
            .frame(width: 248, alignment: .leading)
            try write("list-three-\(name)", view, to: dir)
        }
    }

    func testRenderHistory() throws {
        let dir = try renderDir()
        func row(_ i: Int, serial: String) -> JobLogRow {
            let start = Self.now - Double(i) * 7 * 3600
            return JobLogRow(
                serial: serial,
                name: serial.uppercased(),
                jobId: "t\(i)",
                job: i % 4 == 3 ? nil : ["Benchy", "Print in Parts", "A very long job name that will not fit"][i % 3],
                filament: "PLA",
                startAt: start,
                endedAt: i == 0 ? nil : start + Double(i % 5 + 1) * 3600 + 1200,
                outcome: i == 0 ? nil : i % 6 == 2 ? JobLog.outcomeFail : JobLog.outcomeOK
            )
        }
        let few = (0..<4).map { row($0, serial: "x2d") }
        let many = (0..<JobLog.cap).map { row($0, serial: $0 % 2 == 0 ? "x2d" : "p1s") }
        for (name, rows) in [("empty", [JobLogRow]()), ("few", few), ("many", many)] {
            try write("history-\(name)", HistoryView(rows: rows, now: Self.now, onExport: {}, onClose: {}), to: dir)
        }
    }

    func testRenderSetup() throws {
        let dir = try renderDir()
        for (name, flow) in Self.setupStates() {
            try write("setup-\(name)", SetupView(flow: flow), to: dir)
        }
    }

    private func card(row: Printer, endedAt: Date?, reason: String?, onUpdateCode: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                headline: GlanceContent.headline(row),
                subtitle: GlanceContent.subtitle(row),
                state: row.state
            )
            PrinterDetail(row: row, endedAt: endedAt, now: Self.now, disconnectReason: reason, onUpdateCode: onUpdateCode)
        }
        .padding(14)
        .frame(width: 248, alignment: .leading)
    }

    // MARK: - States

    private static func detailStates() -> [(String, Printer, Date?, String?)] {
        let printing = running("RUNNING")
        var dual = printing
        dual.nozzle = "Left"

        var runout = printing
        runout.filamentRemain = 6
        runout.runout = Runout(percent: 78, at: "15:45", tray: "A1", name: "PLA Matte", color: "F5C6A0FF")
        var runoutBackup = runout
        runoutBackup.runout?.backup = "A3"
        var runoutPaused = running("PAUSE")
        runoutPaused.runout = Runout(percent: 78, tray: "A1", name: "PLA Matte", color: "F5C6A0FF")

        var starting = running("PREPARE")
        starting.percent = 0
        starting.layer = 0
        starting.stage = "Heating"
        starting.nozzleTemp = Temp(current: 186, target: 220)
        starting.bedTemp = Temp(current: 48, target: 60)
        var soaking = starting
        soaking.nozzle = "Left"
        soaking.nozzleTemp = Temp(current: 25, target: 0)
        soaking.bedTemp = Temp(current: 88, target: 90)
        soaking.chamberTemp = Temp(current: 38, target: 60)

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
        var overheated = failed
        overheated.hmsCode = nil
        overheated.printError = "0300-806E"

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
            ("printing-runout", runout, nil, nil),
            ("printing-runout-backup", runoutBackup, nil, nil),
            ("paused-runout", runoutPaused, nil, nil),
            ("starting", starting, nil, nil),
            ("starting-chamber", soaking, nil, nil),
            ("paused-code", paused, nil, nil),
            ("paused-bare", pausedBare, nil, nil),
            ("failed-code", failed, nil, nil),
            ("failed-reason", overheated, nil, nil),
            ("finished-40m", finished, now - 40 * 60, nil),
            ("finished-unknown", finished, nil, nil),
            ("finished-2d", finished, now - 51 * 3600, nil),
            ("idle-one-ams", idle(oneAMS), nil, nil),
            ("idle-two-ams-ext", idle(twoAMSExternal), nil, nil),
            ("idle-ht-dual-ext", idle(htDualExternal), nil, nil),
            ("idle-ams-no-humidity", idle(["ams": ["ams": [["id": "0", "tray": fourTrays]]]]), nil, nil),
            ("offline-was-printing", offlinePrinting, nil, "connect timed out"),
            ("offline-was-due", offlineDue, nil, "connect timed out"),
            ("offline-was-paused", offlinePaused, nil, "connect timed out"),
            ("offline-was-idle", offlineIdle, nil, "ECONNREFUSED"),
            ("offline-never", offlineNever, nil, "MQTT CONNACK 5"),
        ]
    }

    private static let setupSaved = SavedPrinters(
        printers: [PrinterSettings(ip: "192.168.1.21", serial: "00M09A350100123", accessCode: "12345678", name: "Office X1C")],
        focusId: nil
    )

    private static let setupHits = [
        PrinterDiscovery.Hit(ip: "192.168.1.20", serial: "01P00A411800456", name: "Garage P1S", model: "C12"),
        PrinterDiscovery.Hit(ip: "192.168.1.21", serial: "00M09A350100123", name: "Office X1C", model: "BL-P001"),
        PrinterDiscovery.Hit(ip: "192.168.1.22", serial: "0309DA123456789", name: "", model: "N1"),
    ]

    private static func setupStates() -> [(String, SetupFlow)] {
        func flow(_ mode: SetupWindow.Mode = .add, _ configure: (SetupFlow) -> Void) -> SetupFlow {
            let f = SetupFlow(mode: mode, saved: setupSaved)
            configure(f)
            return f
        }
        return [
            ("searching", flow { $0.scanning = true }),
            ("found", flow {
                $0.found = setupHits
                $0.pick(setupHits[0])
                $0.draft.accessCode = "1234"
            }),
            ("nothing-found", flow { $0.manual = true }),
            ("manual", flow {
                $0.manual = true
                $0.draft = PrinterSettings(ip: "192.168.1.20", serial: "01P00A411800456", accessCode: "AB12cd34", name: "")
            }),
            ("edit", flow(.edit(serial: "00M09A350100123")) { $0.found = setupHits }),
            ("connecting", flow {
                $0.found = setupHits
                $0.pick(setupHits[0])
                $0.draft.accessCode = "12345678"
                $0.phase = .connecting
            }),
            ("connected", flow {
                $0.found = setupHits
                $0.pick(setupHits[0])
                $0.draft.accessCode = "12345678"
                $0.phase = .connected
            }),
            ("failed-rejected", flow {
                $0.found = setupHits
                $0.pick(setupHits[0])
                $0.draft.accessCode = "12345678"
                $0.phase = .failed(SetupFlow.failureMessage("MQTT CONNACK 5", ip: "192.168.1.20"))
            }),
            ("failed-refused", flow {
                $0.manual = true
                $0.draft = PrinterSettings(ip: "192.168.1.20", serial: "01P00A411800456", accessCode: "12345678", name: "")
                $0.phase = .failed(SetupFlow.failureMessage("ECONNREFUSED", ip: "192.168.1.20"))
            }),
            ("failed-no-answer", flow {
                $0.manual = true
                $0.draft = PrinterSettings(ip: "192.168.1.20", serial: "01P00A411800456", accessCode: "12345678", name: "")
                $0.phase = .failed(SetupFlow.failureMessage(nil, ip: "192.168.1.20"))
            }),
            ("welcome", flow { $0.phase = .welcome }),
            ("welcome-approval", flow {
                $0.phase = .welcome
                $0.loginNeedsApproval = true
            }),
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
        p.amsUnits = BambuPrint.amsUnits(oneAMS)
        return p
    }

    private static func idle(_ printObj: [String: Any]) -> Printer {
        var p = Printer(id: "x2d", name: "X2D", state: "IDLE")
        p.trays = BambuPrint.trays(printObj)
        p.amsUnits = BambuPrint.amsUnits(printObj)
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

    private static let htDualExternal: [String: Any] = [
        "ams": ["ams": [
            ["id": "0", "info": "1003", "humidity": "4", "humidity_raw": "31", "tray": fourTrays],
            ["id": "128", "info": "4", "humidity": "3", "humidity_raw": "45", "tray": [
                ["id": "0", "tray_type": "PA-CF", "tray_info_idx": "GFN03", "remain": 70, "tray_color": "333333FF"],
            ]],
        ]],
        "vir_slot": [
            ["id": "255", "tray_type": "TPU", "tray_info_idx": "GFU01", "remain": 30, "tray_color": "FF6600FF"],
            ["id": "254", "tray_type": "PLA", "tray_info_idx": "GFA00", "remain": 95, "tray_color": "FFFFFFFF"],
        ],
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
