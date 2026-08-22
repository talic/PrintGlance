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

    func testSuiteDefaultsStillStoreAccessCode() throws {
        let name = "PrintGlance.keychain.\(UUID().uuidString)"
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
}
