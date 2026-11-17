import XCTest
@testable import PrintGlance

final class AccessCodeStoreTests: XCTestCase {
    func testKeychainRoundTripAndDelete() {
        let service = "local.PrintGlance.test.\(UUID().uuidString)"
        XCTAssertNil(AccessCodeStore.get("01S123", service: service))
        AccessCodeStore.set("01S123", "secret-code", service: service)
        XCTAssertEqual(AccessCodeStore.get("01S123", service: service), "secret-code")
        AccessCodeStore.set("01S123", "rotated", service: service)
        XCTAssertEqual(AccessCodeStore.get("01S123", service: service), "rotated")
        AccessCodeStore.delete("01S123", service: service)
        XCTAssertNil(AccessCodeStore.get("01S123", service: service))
    }

    func testSaveWritesAccessCodeOnPrinterRow() throws {
        let name = "PrintGlance.prefs.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.removePersistentDomain(forName: name)
        let saved = SavedPrinters(
            printers: [PrinterSettings(ip: "192.0.2.10", serial: "01S123", accessCode: "code", name: "X2D")],
            focusId: nil
        )
        saved.save(to: d)
        let raw = try XCTUnwrap(d.array(forKey: SavedPrinters.printersKey) as? [[String: String]])
        XCTAssertEqual(raw.first?["accessCode"], "code")
        XCTAssertEqual(SavedPrinters.load(from: d).printers.first?.accessCode, "code")
    }

    func testEmptyRowTakesAccessCodeFromKeychainOnce() throws {
        let serial = "test-\(UUID().uuidString)"
        AccessCodeStore.set(serial, "from-kc")
        defer { AccessCodeStore.delete(serial) }
        let name = "PrintGlance.prefs.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.removePersistentDomain(forName: name)
        SavedPrinters(
            printers: [PrinterSettings(ip: "192.0.2.10", serial: serial, accessCode: "", name: "X2D")],
            focusId: nil
        ).save(to: d)
        let loaded = SavedPrinters.load(from: d)
        XCTAssertEqual(loaded.printers.first?.accessCode, "from-kc")
        let raw = try XCTUnwrap(d.array(forKey: SavedPrinters.printersKey) as? [[String: String]])
        XCTAssertEqual(raw.first?["accessCode"], "from-kc")
        XCTAssertNil(AccessCodeStore.get(serial))
    }

    func testChangingIPTouchesOnlyThatRow() {
        let saved = SavedPrinters(
            printers: [
                PrinterSettings(ip: "192.0.2.10", serial: "AAA", accessCode: "a", name: "A"),
                PrinterSettings(ip: "192.0.2.11", serial: "BBB", accessCode: "b", name: "B"),
            ],
            focusId: "BBB"
        )
        let next = saved.changingIP(serial: " aaa ", to: "192.0.2.20")
        XCTAssertEqual(next?.printers.count, 2)
        XCTAssertEqual(next?.printers[0].ip, "192.0.2.20")
        XCTAssertEqual(next?.printers[0].serial, "AAA")
        XCTAssertEqual(next?.printers[0].accessCode, "a")
        XCTAssertEqual(next?.printers[0].name, "A")
        XCTAssertEqual(next?.printers[1], saved.printers[1])
        XCTAssertEqual(next?.focusId, "BBB")
        XCTAssertNil(saved.changingIP(serial: "missing", to: "192.0.2.30"))
        XCTAssertNil(saved.changingIP(serial: "AAA", to: "192.0.2.10"))
    }

    /// MQTT topics are case-sensitive and Bambu's serials are upper case: a serial typed in lower case, or
    /// saved that way by an older build, is dialed upper case.
    func testSerialsAreSavedUpperCase() throws {
        XCTAssertEqual(PrinterSettings(ip: " 192.0.2.10 ", serial: " 20p9aj5b0700123\n", accessCode: "a", name: "").trimmed.serial, "20P9AJ5B0700123")
        let name = "PrintGlance.prefs.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set([["ip": "192.0.2.10", "serial": "20p9aj5b0700123", "name": "", "accessCode": "a"]], forKey: SavedPrinters.printersKey)
        d.set("20p9aj5b0700123", forKey: SavedPrinters.focusKey)
        let loaded = SavedPrinters.load(from: d)
        XCTAssertEqual(loaded.printers.map(\.serial), ["20P9AJ5B0700123"])
        XCTAssertEqual(loaded.focusId, "20P9AJ5B0700123")
    }
}
