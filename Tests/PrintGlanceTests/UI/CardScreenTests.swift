import XCTest
@testable import PrintGlance

/// The print card in each state, read through accessibility the way a VoiceOver user meets it.
/// Text that depends on this Mac's clock format is matched by prefix.
@MainActor
final class CardScreenTests: XCTestCase {
    private func screen(
        _ row: Printer,
        endedAt: Date? = nil,
        reason: String? = nil,
        onUpdateCode: (() -> Void)? = nil
    ) throws -> Screen {
        let s = try Screen(Rows.card(row, endedAt: endedAt, reason: reason, onUpdateCode: onUpdateCode))
        assertReadsWell(s)
        return s
    }

    func testPrinting() throws {
        let s = try screen(Rows.printing())
        XCTAssertEqual(s.texts, ["Benchy", "Printing", "16:25", "1h 24m left", "52%", "Layer 18 / 29", "PLA Matte  80%"])
        XCTAssertTrue(s.controls.isEmpty, "nothing to press while it prints")
    }

    func testPrintingOnADualNozzlePrinterNamesTheNozzle() throws {
        var row = Rows.printing()
        row.nozzle = "Left"
        XCTAssertTrue(try screen(row).has("PLA Matte  80% · Left"))
    }

    func testRunoutLineUnderTheBar() throws {
        var row = Rows.printing()
        row.runout = Runout(percent: 78, at: "15:45", tray: "A1", name: "PLA Matte", color: "F5C6A0FF", backup: "A3")
        let s = try screen(row)
        XCTAssertTrue(s.has("PLA Matte in A1 runs out around 15:45. AMS may switch to A3."), "\(s.texts)")
    }

    func testStartingShowsTheStageAndHeaters() throws {
        let s = try screen(Rows.starting())
        XCTAssertEqual(Array(s.texts.prefix(2)), ["Benchy", "Heating"])
        XCTAssertTrue(s.has("Nozzle 186 / 220° · Bed 48 / 60°"))
        XCTAssertTrue(s.has("0%"))
    }

    func testPausedSaysWhyAndOffersTheLookup() throws {
        let s = try screen(Rows.paused())
        XCTAssertEqual(Array(s.texts.prefix(5)), ["Benchy", "Paused", "1h 24m left", "52%", "Layer 18 / 29"])
        XCTAssertFalse(s.has("16:25"), "a paused finish time slides, so the card shows time left")
        XCTAssertTrue(s.has("Filament ran out in AMS A, slot 1."))
        XCTAssertTrue(s.has("Error 0700-2000-0002-0001"))
        XCTAssertEqual(try s.control("Look up error 0700-2000-0002-0001").role, "AXLink")
        XCTAssertTrue(s.has("AMS A · Humid"), "trays matter when you walk to a paused printer")
        XCTAssertTrue(s.has("A1 · PLA Matte  80%"))
    }

    func testPausedWithoutACodeSaysSo() throws {
        let s = try screen(Rows.paused(hms: nil))
        XCTAssertTrue(s.has("No error reported."))
        XCTAssertFalse(s.controls.contains { $0.role == "AXLink" })
    }

    func testFailed() throws {
        let s = try screen(Rows.failed())
        XCTAssertEqual(Array(s.texts.prefix(3)), ["Benchy", "Failed", "X2D"])
        XCTAssertTrue(s.has("The nozzle overheated. Turn the printer off and have it checked."))
        XCTAssertTrue(s.has("Error 0300-806E"))
        XCTAssertFalse(s.has("37%"), "no progress bar once it stopped")
    }

    func testFinishedSaysHowLongAgo() throws {
        let s = try screen(Rows.finished(), endedAt: Rows.now - 40 * 60)
        XCTAssertEqual(Array(s.texts.prefix(4)), ["Benchy", "Finished", "40m ago", "X2D"])
        XCTAssertTrue(s.has("A1 · PLA Matte  80%"))
    }

    func testFinishedWhileTheAppWasClosedHasNoTime() throws {
        let s = try screen(Rows.finished())
        XCTAssertEqual(Array(s.texts.prefix(3)), ["Benchy", "Finished", "X2D"])
        XCTAssertFalse(s.texts.contains { $0.hasSuffix("ago") })
    }

    func testIdleListsTheSlotsLikeThePrinter() throws {
        let s = try screen(Rows.idle())
        XCTAssertEqual(s.texts, ["X2D", "Idle", "AMS A · Humid", "A1 · PLA Matte  80%", "A2 · PLA Basic  12%", "A4 · PETG HF  40%"])
    }

    func testIdleWithEveryUnitAndExternalSpools() throws {
        let s = try screen(Rows.idle(Rows.fullAMS))
        for header in ["AMS A · Dry", "AMS D · Dry", "AMS HT-A · 45%"] {
            XCTAssertTrue(s.has(header), header)
        }
        XCTAssertTrue(s.has("HT-A · PLA Matte  80%"))
        XCTAssertTrue(s.has("External R · TPU 95A  30%"))
        XCTAssertTrue(s.has("External L · PLA Basic  95%"))
    }

    func testOfflineKeepsWhatItLastKnew() throws {
        let s = try screen(Rows.offline(was: "RUNNING"), reason: "connect timed out")
        XCTAssertEqual(Array(s.texts.prefix(2)), ["Benchy", "Offline"])
        XCTAssertTrue(s.texts.contains { $0.hasPrefix("Last update ") }, "\(s.texts)")
        XCTAssertTrue(s.has("Was printing · 52% · Layer 18 / 29"))
        XCTAssertTrue(s.texts.contains { $0.hasPrefix("Expected to finish ") })
        XCTAssertTrue(s.has("Can't reach the printer. Check Wi-Fi and the IP address."))
        XCTAssertFalse(s.has("52%"), "no live bar for a printer we can't hear")
    }

    func testOfflinePaused() throws {
        let s = try screen(Rows.offline(was: "PAUSE"), reason: "ECONNREFUSED")
        XCTAssertTrue(s.has("Was paused at 52%"))
        XCTAssertTrue(s.has(GlanceCopy.feedDownDetail(reason: "ECONNREFUSED")))
    }

    func testRejectedCodeOffersToUpdateIt() throws {
        var pressed = 0
        let s = try screen(Printer(id: "x2d", name: "X2D", state: "OFFLINE"), reason: "MQTT CONNACK 5", onUpdateCode: { pressed += 1 })
        XCTAssertTrue(s.has("The access code was rejected. Check the access code on the printer's LAN or Network page."))
        try s.press("Update Access Code…")
        XCTAssertEqual(pressed, 1)
    }

    // MARK: - Menu bar and printer list

    func testMenuBarItemReadsAsOneSentence() throws {
        let s = try Screen(StripLabel(strip: GlanceContent.strip(row: Rows.printing())))
        XCTAssertEqual(s.elements.map(\.label), ["X2D, printing, 52 percent, finish 16:25, layer 18 / 29"])
    }

    func testPrinterListRowsSayStateAndProgress() throws {
        var p1s = Rows.paused()
        p1s.id = "p1s"
        p1s.name = "P1S"
        var a1 = Rows.idle()
        a1.id = "a1"
        a1.name = "A1 mini"
        var selected: [String] = []
        let s = try Screen(PrinterList(
            printers: [Rows.printing(), p1s, a1],
            shownId: "x2d",
            onSelect: { selected.append($0) },
            onEdit: { _ in },
            onRemove: { _ in }
        ).frame(width: 220))
        XCTAssertEqual(s.controls.map(\.label), [
            "X2D, Printing, 52 percent, finish 16:25",
            "P1S, Paused, 52 percent",
            "A1 mini, Idle",
        ])
        try s.press("P1S, Paused, 52 percent")
        XCTAssertEqual(selected, ["p1s"])
    }
}

/// Every button, link, field, and toggle has a name VoiceOver can say, and no Swift optional
/// leaked into the text ("Optional(…)" is what interpolating one prints).
@MainActor
func assertReadsWell(_ s: Screen, file: StaticString = #filePath, line: UInt = #line) {
    for c in s.controls where c.label.isEmpty {
        XCTFail("unnamed \(c.role) (value \"\(c.value)\")", file: file, line: line)
    }
    for e in s.elements where e.role == "AXImage" && e.label.isEmpty {
        XCTFail("unnamed image", file: file, line: line)
    }
    for e in s.elements where e.text.contains("Optional(") {
        XCTFail("optional in \"\(e.text)\"", file: file, line: line)
    }
}
