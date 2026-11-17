import XCTest
@testable import PrintGlance

/// The print card in each state, read through accessibility the way a VoiceOver user meets it.
/// Text that depends on this Mac's clock format is matched by prefix.
@MainActor
final class CardScreenTests: XCTestCase {
    private func screen(
        _ row: Printer,
        endedAt: Date? = nil,
        startedAt: Date? = nil,
        reason: String? = nil,
        namingPrinter: Bool = false,
        onUpdateCode: (() -> Void)? = nil
    ) throws -> Screen {
        let s = try Screen(Rows.card(
            row, endedAt: endedAt, startedAt: startedAt, reason: reason, namingPrinter: namingPrinter, onUpdateCode: onUpdateCode
        ))
        assertReadsWell(s)
        return s
    }

    func testPrinting() throws {
        let s = try screen(Rows.printing())
        XCTAssertEqual(s.texts, ["Benchy", "Printing", "16:25", "1h 24m left", "52%", "Layer 18 / 29", "PLA Matte  80%"])
        XCTAssertTrue(s.controls.isEmpty, "nothing to press while it prints")
    }

    func testWithSeveralPrintersTheCardNamesItsPrinter() throws {
        XCTAssertEqual(Array(try screen(Rows.printing(), namingPrinter: true).texts.prefix(2)), ["Benchy", "X2D · Printing"])
        XCTAssertEqual(Array(try screen(Rows.paused(), namingPrinter: true).texts.prefix(2)), ["Benchy", "X2D · Paused"])
        XCTAssertEqual(Array(try screen(Rows.idle(), namingPrinter: true).texts.prefix(2)), ["X2D", "Idle"])
        XCTAssertFalse(try screen(Rows.finished(), endedAt: Rows.now - 600, namingPrinter: true).has("X2D"),
                       "no separate printer-name line any more")
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
        XCTAssertEqual(s.texts, ["Benchy", "Heating", "16:25", "1h 24m left", "Nozzle 186 / 220° · Bed 48 / 60°", "PLA Matte  80%"],
                       "the heaters come right under the time, and there's no 0% bar or layer 0 yet")
    }

    func testPausedSaysWhyAndOffersTheLookup() throws {
        let s = try screen(Rows.paused())
        XCTAssertEqual(s.texts, [
            "Benchy", "Paused",
            "Filament ran out in AMS A, slot 1.", "Error 0700-2000-0002-0001",
            "52%", "Layer 18 / 29", "PLA Matte  80%",
            "1h 24m left",
            "AMS A · Humid", "A1 · PLA Matte  80%", "A2 · PLA Basic  12%", "A3 · Empty", "A4 · PETG HF  40%",
        ], "the reason leads; time left, which holds still while paused, follows the bar")
        XCTAssertFalse(s.has("16:25"), "a paused finish time slides, so the card shows time left")
        XCTAssertEqual(try s.control("Look up error 0700-2000-0002-0001").role, "AXLink")
    }

    func testPausedWithTwoCodesExplainsEach() throws {
        var row = Rows.paused()
        row.printError = "0700-8002"
        let s = try screen(row)
        XCTAssertEqual(Array(s.texts.prefix(6)), [
            "Benchy", "Paused",
            "Filament ran out in AMS A, slot 1.", "Error 0700-2000-0002-0001",
            "The filament cutter is stuck.", "Error 0700-8002",
        ])
        XCTAssertEqual(s.controls.map(\.label), ["Look up error 0700-2000-0002-0001", "Look up error 0700-8002"])

        row.hmsCode = "0700-4500-0002-0003"
        let same = try screen(row)
        XCTAssertEqual(Array(same.texts.prefix(5)), [
            "Benchy", "Paused", "The filament cutter is stuck.", "Error 0700-4500-0002-0003", "Error 0700-8002",
        ], "one reason, said once")
    }

    func testPausedWithoutACodeSaysSo() throws {
        let s = try screen(Rows.paused(hms: nil))
        XCTAssertEqual(Array(s.texts.prefix(4)), ["Benchy", "Paused", "No error reported.", "52%"])
        XCTAssertFalse(s.controls.contains { $0.role == "AXLink" })
    }

    func testFailed() throws {
        let s = try screen(Rows.failed())
        XCTAssertEqual(Array(s.texts.prefix(6)), [
            "Benchy", "Failed",
            "The nozzle overheated. Turn the printer off and have it checked.", "Error 0300-806E",
            "Stopped at 37% · Layer 18 / 29", "AMS A · Humid",
        ])
        XCTAssertFalse(s.has("37%"), "no progress bar once it stopped")
    }

    func testFailedBeforeItGotGoingHasNoStoppedLine() throws {
        var row = Rows.failed()
        row.percent = 0
        XCTAssertFalse(try screen(row).texts.contains { $0.hasPrefix("Stopped at") })
    }

    func testFinishedSaysHowLongAgoAndHowLongItTook() throws {
        let ended = Rows.now - 40 * 60
        let s = try screen(Rows.finished(), endedAt: ended, startedAt: ended - 283 * 60)
        XCTAssertEqual(Array(s.texts.prefix(5)), ["Benchy", "Finished", "40m ago", "Took 4h 43m", "AMS A · Humid"])
        XCTAssertTrue(s.has("A1 · PLA Matte  80%"))
    }

    func testFinishedHoursAgoShowsWhenItFinished() throws {
        let ended = Rows.now - 3 * 3600
        let s = try screen(Rows.finished(), endedAt: ended, startedAt: ended - 283 * 60)
        XCTAssertEqual(s.texts[2], GlanceContent.dayTime(ended, now: Rows.now), "the clock time, not \"3h 00m ago\"")
        XCTAssertEqual(s.texts[3], "Took 4h 43m")
        XCTAssertFalse(s.texts.contains { $0.hasSuffix("ago") })
    }

    func testFinishedWhileTheAppWasClosedHasNoTime() throws {
        let s = try screen(Rows.finished())
        XCTAssertEqual(Array(s.texts.prefix(3)), ["Benchy", "Finished", "AMS A · Humid"])
        XCTAssertFalse(s.texts.contains { $0.hasSuffix("ago") || $0.hasPrefix("Took") })
    }

    func testIdleListsTheSlotsLikeThePrinter() throws {
        let s = try screen(Rows.idle())
        XCTAssertEqual(s.texts, ["X2D", "Idle", "AMS A · Humid", "A1 · PLA Matte  80%", "A2 · PLA Basic  12%", "A3 · Empty", "A4 · PETG HF  40%"])
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

    func testSwitchedOffReadsCalm() throws {
        let s = try screen(Rows.offline(was: "IDLE"), reason: "connect timed out")
        XCTAssertEqual(Array(s.texts.prefix(2)), ["X2D", "Offline"])
        XCTAssertTrue(s.texts[2].hasPrefix("Last update "), "\(s.texts)")
        XCTAssertEqual(Array(s.texts.dropFirst(3)), ["It may be switched off. If it's on, check Wi-Fi and the IP address."])
        XCTAssertTrue(s.controls.isEmpty, "nothing to fix")

        let never = try screen(Printer(id: "x2d", name: "X2D", state: "OFFLINE"), reason: "ECONNREFUSED")
        XCTAssertEqual(never.texts, [
            "X2D",
            "Offline",
            "It may be switched off or still starting up. If it's on, check the IP address on the printer's LAN or Network page.",
        ])
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

    func testPrinterListSaysCanceledAndOffline() throws {
        var canceled = Rows.failed()
        canceled.printError = GlanceContent.cancelCode
        var off = Rows.offline(was: "IDLE")
        off.id = "p1s"
        off.name = "P1S"
        let s = try Screen(PrinterList(
            printers: [canceled, off],
            shownId: "x2d",
            onSelect: { _ in },
            onEdit: { _ in },
            onRemove: { _ in }
        ).frame(width: 220))
        assertReadsWell(s)
        XCTAssertEqual(s.controls.map(\.label), ["X2D, Canceled", "P1S, Offline"])
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
