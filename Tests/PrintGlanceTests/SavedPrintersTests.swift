import XCTest
@testable import PrintGlance

/// The saved printer list: limits, edits, focus, and reading old or damaged preferences.
final class SavedPrintersTests: XCTestCase {
    private func printer(_ n: Int, code: String = "code") -> PrinterSettings {
        PrinterSettings(ip: "192.0.2.\(n)", serial: "SERIAL\(n)", accessCode: code, name: "P\(n)")
    }

    func testAddingTrimsAndCapsAtFour() {
        var saved = SavedPrinters.empty
        saved = saved.adding(PrinterSettings(ip: " 192.0.2.1\n", serial: " SERIAL1 ", accessCode: " code ", name: " P1 "))
        XCTAssertEqual(saved.printers, [printer(1)])
        for n in 2...5 { saved = saved.adding(printer(n)) }
        XCTAssertEqual(saved.printers.map(\.serial), ["SERIAL1", "SERIAL2", "SERIAL3", "SERIAL4"], "a fifth is ignored")
        XCTAssertFalse(saved.canAdd)
        XCTAssertEqual(saved.adding(printer(2, code: "new")).printers[1].accessCode, "new", "a known serial updates in place, even when full")
    }

    func testCompleteNeedsAddressSerialAndCode() {
        XCTAssertTrue(printer(1).isComplete)
        for broken in [PrinterSettings(ip: "", serial: "S", accessCode: "c", name: ""),
                       PrinterSettings(ip: "1.2.3.4", serial: "", accessCode: "c", name: ""),
                       PrinterSettings(ip: "1.2.3.4", serial: "S", accessCode: "", name: "")] {
            XCTAssertFalse(broken.isComplete)
            XCTAssertFalse(SavedPrinters(printers: [broken], focusId: nil).isComplete)
        }
        XCTAssertEqual(PrinterSettings.empty.displayName, "Printer")
    }

    func testRemovingTheFocusedPrinterClearsFocus() {
        let saved = SavedPrinters(printers: [printer(1), printer(2)], focusId: "SERIAL2")
        XCTAssertNil(saved.removing(serial: "SERIAL2").focusId)
        XCTAssertEqual(saved.removing(serial: "SERIAL1").focusId, "SERIAL2")
        XCTAssertEqual(saved.removing(serial: "nope"), saved)
    }

    func testEditingTheSerialMovesFocusWithIt() {
        let saved = SavedPrinters(printers: [printer(1), printer(2)], focusId: "SERIAL1")
        var renamed = printer(1)
        renamed.serial = "SERIAL9"
        let next = saved.replacing(renamed, serial: "SERIAL1")
        XCTAssertEqual(next.printers.map(\.serial), ["SERIAL9", "SERIAL2"])
        XCTAssertEqual(next.focusId, "SERIAL9")
        XCTAssertEqual(saved.replacing(printer(3), serial: "missing").printers.count, 3, "an unknown row is added")
    }

    func testDamagedPreferencesLoadWhatTheyCan() throws {
        let d = scratchDefaults()
        d.set([["ip": "192.0.2.1", "serial": "S1", "accessCode": "c", "name": "A"], "junk", 42, ["serial": 7]], forKey: SavedPrinters.printersKey)
        let loaded = SavedPrinters.load(from: d)
        XCTAssertEqual(loaded.printers.first, PrinterSettings(ip: "192.0.2.1", serial: "S1", accessCode: "c", name: "A"))
        XCTAssertEqual(loaded.printers.count, 2, "a dict with wrong types loads as an incomplete row")
        XCTAssertFalse(loaded.printers[1].isComplete)
    }

    func testSaveAndLoadRoundTripWithFocus() {
        let d = scratchDefaults()
        let saved = SavedPrinters(printers: [printer(1), printer(2)], focusId: "SERIAL2")
        saved.save(to: d)
        XCTAssertEqual(SavedPrinters.load(from: d), saved)
        SavedPrinters(printers: [printer(1)], focusId: nil).save(to: d)
        XCTAssertNil(SavedPrinters.load(from: d).focusId)
    }

    func testAnEmptyListStaysEmptyAfterLegacyKeysAreGone() {
        let d = scratchDefaults()
        SavedPrinters.empty.save(to: d)
        d.set("192.0.2.9", forKey: SavedPrinters.legacyIP)
        XCTAssertEqual(SavedPrinters.load(from: d).printers, [], "the new key wins once it exists, even empty")
    }
}
