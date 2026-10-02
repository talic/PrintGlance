import Foundation
import XCTest
@testable import PrintGlance

/// The promises in the README's "Private and read-only" line, and hostile input from the LAN.
/// MQTT framing attacks are in `MQTTWireTests`; the Python feed's are in `Tests/Feed`.
@MainActor
final class SecurityTests: XCTestCase {
    private let secret = "SECRET-77"

    // MARK: - The access code stays the MQTT password and nothing else

    func testAccessCodeIsOnlyEverTheMQTTPassword() async throws {
        let h = ModelHarness(self)
        let printer = PrinterSettings.x2d(code: secret)
        h.network.hits = [PrinterDiscovery.Hit(ip: "192.0.2.99", serial: printer.serial, name: "X2D", model: "N6")]
        let link = try XCTUnwrap(h.add(printer).first)
        link.drop("MQTT CONNACK 5")
        link.accept()
        link.report(Report.running().merging(Report.ams(remain: 10)))
        link.report(["gcode_state": "PAUSE", "print_error": 0x0300_8001])
        link.drop("ECONNREFUSED")
        let adopted = await eventually { link.dials.last?.host == "192.0.2.99" }
        XCTAssertTrue(adopted)
        link.accept()

        XCTAssertTrue(link.dials.allSatisfy { $0.password == secret && !$0.clientID.contains(secret) && $0.username == "bblp" })
        XCTAssertFalse(h.logText.isEmpty, "the session was logged")
        XCTAssertFalse(h.logText.contains(secret), "log:\n\(h.logText)")
        for n in h.notifications.posted {
            XCTAssertFalse(n.title.contains(secret) || n.body.contains(secret), n.body)
            XCTAssertFalse(n.body.contains("192.0.2."), "notices name the printer, not its address: \(n.body)")
        }
        XCTAssertFalse(link.publishes.contains { $0.payload.contains(secret) })
    }

    // MARK: - Read-only: the app never commands a printer

    func testOnlyEverAsksForAFullReport() throws {
        let h = ModelHarness(self)
        let x2d = PrinterSettings.x2d()
        let p1s = PrinterSettings.p1s()
        let links = h.add(x2d, p1s)
        for link in links {
            link.accept()
            link.report(Report.running())
            link.report(["gcode_state": "PAUSE", "hms": [["attr": 0x0700_2000, "code": 0x0002_0001]]])
            link.report(Report.state("FAILED"))
            link.drop("closed")
            link.accept()
        }
        h.model.focusPrinter(p1s.serial)
        h.model.notifyPrefs.quietHours = true
        h.model.removePrinter(serial: x2d.serial)

        let pushall = #"{"pushing":{"command":"pushall","sequence_id":"0"}}"#
        for client in h.printers.clients {
            guard let serial = [x2d, p1s].first(where: { client.dials.first?.clientID.contains($0.serial.suffix(6)) == true })?.serial else {
                continue
            }
            for publish in client.publishes {
                XCTAssertEqual(publish.topic, "device/\(serial)/request")
                XCTAssertEqual(publish.payload, pushall, "no pause, stop, resume, print, or settings, ever")
            }
            XCTAssertTrue(client.subscriptions.allSatisfy { $0 == "device/\(serial)/report" })
        }
        XCTAssertFalse(h.printers.clients.flatMap(\.publishes).isEmpty)
    }

    // MARK: - What leaves this Mac

    func testErrorLookupSendsOnlyTheModelPrefix() throws {
        let serial = "20P9AJ5B0700123"
        let hms = GlanceContent.errorLookup(code: "0700-2000-0002-0001", serial: serial)
        XCTAssertEqual(hms.url.scheme, "https")
        XCTAssertEqual(hms.url.host, "e.bambulab.com")
        XCTAssertFalse(hms.url.absoluteString.contains(serial))
        let query = URLComponents(url: hms.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "d" }?.value, "20P", "the model, not the printer")

        let printError = GlanceContent.errorLookup(code: "0300-806E", serial: serial)
        XCTAssertEqual(printError.url.host, "wiki.bambulab.com")
        XCTAssertFalse(printError.url.absoluteString.contains("20P"))
        XCTAssertTrue(printError.copiesCode)
    }

    func testUpdateDownloadsOnlyFromGitHubOverHTTPS() {
        func zip(_ url: String) -> URL? {
            AppUpdate.zipURL(fromAPIJSON: Data(#"{"assets":[{"name":"PrintGlance.zip","browser_download_url":"\#(url)"}]}"#.utf8))
        }
        XCTAssertNotNil(zip("https://github.com/talic/PrintGlance/releases/download/v9.9.9/PrintGlance.zip"))
        for hostile in [
            "https://github.com.evil.example/PrintGlance.zip",
            "https://evil.example/github.com/PrintGlance.zip",
            "https://github.com@evil.example/PrintGlance.zip",
            "https://objects.githubusercontent.com/PrintGlance.zip",
            "http://github.com/talic/PrintGlance.zip",
            "file:///Applications/PrintGlance.app",
            "javascript:alert(1)",
        ] {
            XCTAssertNil(zip(hostile), hostile)
        }
    }

    func testUpdateCheckIdentifiesOnlyTheAppVersion() {
        let session = AppUpdateChecker.makeSession(localVersion: "1.3.0")
        let headers = session.configuration.httpAdditionalHeaders as? [String: String]
        XCTAssertEqual(headers, [
            "User-Agent": "PrintGlance/1.3.0 (+https://github.com/talic/PrintGlance)",
            "Accept": "application/vnd.github+json",
        ])
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 8)
        XCTAssertNil(session.configuration.httpCookieStorage?.cookies?.first, "ephemeral: no cookies kept")
        XCTAssertEqual(AppUpdate.latestAPIURL.host, "api.github.com")
        XCTAssertEqual(AppUpdate.latestAPIURL.scheme, "https")
    }

    // MARK: - Hostile printers

    /// Seeded random reports through the whole pipeline: snapshot merge, card, menu bar, notifications,
    /// history, runout, and finishing-soon. A printer, or anything on the LAN pretending to be one,
    /// must not be able to crash the app.
    func testRandomReportsNeverCrashOrLeakOptionals() throws {
        var rng = SplitMix64(seed: 0x5EED_1234)
        let h = ModelHarness(self)
        let links = h.add(.x2d(), .p1s())
        links.forEach { $0.accept() }
        for i in 0..<400 {
            let link = links[i % 2]
            link.report(Fuzz.report(&rng))
            if i % 50 == 49 { link.drop(rng.pick(["closed", "MQTT CONNACK 5", "ECONNREFUSED", nil])) ; link.accept() }
            for row in h.doc?.printers ?? [] {
                let strings = [GlanceContent.headline(row), GlanceContent.subtitle(row), GlanceContent.listDetail(row)]
                    + [GlanceContent.hero(row), GlanceContent.remainingLine(row), GlanceContent.layerLine(row),
                       GlanceContent.filamentLine(row), GlanceContent.heatLine(row), GlanceContent.errorReason(row)].compactMap { $0 }
                    + GlanceContent.offlineLines(row, now: Date()) + GlanceContent.errorCodes(row)
                    + GlanceContent.amsGroups(row).flatMap { [$0.header].compactMap { $0 } + $0.trays.map(GlanceContent.trayLine) }
                    + [GlanceContent.strip(row: row).title, GlanceContent.strip(row: row).accessibilityLabel]
                for s in strings {
                    XCTAssertFalse(s.contains("Optional("), s)
                }
            }
        }
        for n in h.notifications.posted {
            XCTAssertFalse(n.body.contains("Optional(") || n.title.contains("Optional("), n.body)
        }
    }

    func testRandomErrorCodesNeverCrash() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<2000 {
            let groups = (0..<rng.pick([1, 2, 3, 4, 5])).map { _ in String(rng.next() & 0x1_FFFF, radix: 16) }
            _ = GlanceContent.errorReason(code: groups.joined(separator: rng.pick(["-", "--", " ", ""])))
            _ = BambuPrint.printErrorCode(Int64(bitPattern: rng.next()))
            _ = BambuPrint.firstHMSCode(["hms": [["attr": Int64(bitPattern: rng.next()), "code": Int64(bitPattern: rng.next())]]])
        }
        XCTAssertNil(GlanceContent.errorReason(code: "ZZZZ-0000"))
        XCTAssertNil(GlanceContent.errorReason(code: ""))
    }

    func testDiscoveryRepliesCantPointAtNonPrinterAddresses() {
        func reply(_ location: String, _ extra: String = "NT: urn:bambulab-com:device:3dprinter:1") -> PrinterDiscovery.Hit? {
            PrinterDiscovery.parse("HTTP/1.1 200 OK\r\nLocation: \(location)\r\n\(extra)\r\nUSN: 01P00A411800456\r\n\r\n")
        }
        XCTAssertEqual(reply("192.0.2.30")?.ip, "192.0.2.30")
        XCTAssertEqual(reply("http://192.0.2.30:80/desc.xml")?.ip, "192.0.2.30")
        for hostile in ["239.255.255.250", "255.255.255.255", "0.0.0.0", "printer.local", "evil.example", "256.1.1.1",
                        "[fe80::1]", "192.0.2", "192.0.2.1.5", "", "http://evil.example/192.0.2.30"] {
            XCTAssertNil(reply(hostile), hostile)
        }
        XCTAssertNil(reply("192.0.2.30", "NT: upnp:rootdevice"), "not a Bambu reply")
    }

    func testRandomDiscoveryPacketsNeverCrash() {
        var rng = SplitMix64(seed: 7)
        let keys = ["Location", "USN", "NT", "ST", "DevName.bambu.com", "DevModel.bambu.com", "", ":", "x"]
        for _ in 0..<2000 {
            let lines = (0..<rng.pick([0, 1, 3, 8])).map { _ in
                "\(rng.pick(keys)):\(rng.pick([" ", ""]))\(Fuzz.string(&rng))"
            }
            _ = PrinterDiscovery.parse(lines.joined(separator: rng.pick(["\r\n", "\n", "\r"])))
        }
    }
}

/// Deterministic, so a failure reproduces from its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
}

/// JSON-safe junk shaped like Bambu reports: right keys, any types.
enum Fuzz {
    static func number(_ rng: inout SplitMix64) -> Any {
        rng.pick([
            0, 1, -1, 2, 100, 101, 254, 255, 256, 43_200, 99_999, Int.max, Int.min, Int(Int32.max),
            Int(truncatingIfNeeded: rng.next()), 0.5, -0.5, 1e300, -1e300, 31.96875,
        ] as [Any])
    }

    static func string(_ rng: inout SplitMix64) -> String {
        rng.pick(["", " ", "RUNNING", "PAUSE", "FINISH", "FAILED", "IDLE", "PREPARE", "SLICING", "running",
                  "GFA01", "FFFFFF00", "#00FF00", "zzzzzzzz", "-1", "1e9", "\u{0}", "é", "🧪", "cache/1.gcode",
                  String(repeating: "A", count: 500), "Benchy 0.2mm layer", "255", "4", "1003"])
    }

    static func value(_ rng: inout SplitMix64, depth: Int = 0) -> Any {
        switch rng.next() % (depth > 2 ? 3 : 6) {
        case 0: return number(&rng)
        case 1: return string(&rng)
        case 2: return NSNull()
        case 3: return (0..<Int(rng.next() % 4)).map { _ in value(&rng, depth: depth + 1) }
        case 4: return tray(&rng)
        default: return ["id": value(&rng, depth: depth + 1), "info": value(&rng, depth: depth + 1)]
        }
    }

    static func tray(_ rng: inout SplitMix64) -> [String: Any] {
        var t: [String: Any] = [:]
        for key in ["id", "tray_type", "tray_sub_brands", "tray_info_idx", "remain", "tray_color", "cols"] where rng.next() % 3 != 0 {
            t[key] = key == "cols" ? [string(&rng)] : rng.next() % 2 == 0 ? number(&rng) : string(&rng)
        }
        return t
    }

    static func report(_ rng: inout SplitMix64) -> [String: Any] {
        var r: [String: Any] = [:]
        let scalar = ["gcode_state", "mc_percent", "mc_remaining_time", "layer_num", "total_layer_num", "task_id",
                      "subtask_id", "subtask_name", "gcode_file", "stg_cur", "print_error", "nozzle_temper",
                      "nozzle_target_temper", "bed_temper", "bed_target_temper", "chamber_temper", "ctt"]
        for key in scalar where rng.next() % 2 == 0 {
            r[key] = key == "gcode_state" && rng.next() % 2 == 0 ? rng.pick(["RUNNING", "PAUSE", "FINISH", "FAILED", "IDLE", "PREPARE"])
                : rng.next() % 2 == 0 ? number(&rng) : string(&rng)
        }
        if rng.next() % 2 == 0 {
            let units = (0..<Int(rng.next() % 6)).map { _ -> Any in
                ["id": number(&rng), "humidity": value(&rng), "humidity_raw": value(&rng), "info": value(&rng),
                 "tray": (0..<Int(rng.next() % 5)).map { _ in tray(&rng) }]
            }
            r["ams"] = rng.next() % 5 == 0 ? value(&rng) : ["tray_now": value(&rng), "tray_tar": value(&rng), "ams": units]
        }
        if rng.next() % 3 == 0 { r["vt_tray"] = tray(&rng) }
        if rng.next() % 3 == 0 { r["vir_slot"] = [tray(&rng), tray(&rng)] }
        if rng.next() % 3 == 0 { r["hms"] = (0..<Int(rng.next() % 3)).map { _ in ["attr": number(&rng), "code": number(&rng)] } }
        if rng.next() % 3 == 0 {
            r["device"] = [
                "extruder": ["state": number(&rng), "info": [["id": number(&rng), "temp": number(&rng)], ["id": value(&rng), "temp": value(&rng)]]],
                "bed": ["info": ["temp": number(&rng)]],
                "ctc": ["info": ["temp": value(&rng)]],
                "bed_temp": value(&rng),
            ]
        }
        return r
    }
}
