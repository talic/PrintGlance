import XCTest
@testable import PrintGlance

/// The whole menu bar panel (`GlanceView`) over a model the test feeds, plus the History page.
@MainActor
final class PanelScreenTests: XCTestCase {
    private func panel(_ h: ModelHarness) throws -> Screen {
        let s = try Screen(GlanceView(model: h.model))
        assertReadsWell(s)
        XCTAssertEqual(s.size.width, 248)
        return s
    }

    func testFirstRunOffersAddPrinter() throws {
        let s = try panel(ModelHarness(self))
        XCTAssertEqual(s.texts, ["Add your printer"])
        XCTAssertEqual(s.controls.map(\.label), ["More", "Add Printer"])
    }

    func testConnecting() throws {
        let h = ModelHarness(self)
        h.add(.x2d())
        let s = try panel(h)
        XCTAssertEqual(s.texts, ["Connecting", "Connecting to the printer."])
    }

    func testRejectedCodeBeforeAnyReportOffersToFixIt() throws {
        let h = ModelHarness(self)
        h.add(.x2d()).first?.drop("MQTT CONNACK 5")
        let s = try panel(h)
        XCTAssertEqual(s.texts, [
            "Can't reach printer",
            "The access code was rejected. Check the access code on the printer's LAN or Network page.",
        ])
        XCTAssertNotNil(s.find("Update Access Code…"))
    }

    func testUnreachableWithoutACodeProblemOffersNoButton() throws {
        let h = ModelHarness(self)
        h.add(.x2d()).first?.drop("ECONNREFUSED")
        let s = try panel(h)
        XCTAssertTrue(s.has(GlanceCopy.feedDownDetail(reason: "ECONNREFUSED")))
        XCTAssertNil(s.find("Update Access Code…"))
    }

    func testPrintingCardWithTheListAndSwitchingPrinters() throws {
        let h = ModelHarness(self)
        let links = h.add(.x2d(), .p1s())
        links.forEach { $0.accept() }
        links[0].report(Report.running(minutesLeft: 30))
        links[1].report(Report.running(minutesLeft: 90, job: "Gears", task: "t9"))
        let s = try panel(h)
        XCTAssertEqual(Array(s.texts.prefix(2)), ["Benchy", "Printing"], "the printer finishing soonest")
        let rows = s.controls.filter { $0.label.hasPrefix("X2D,") || $0.label.hasPrefix("P1S,") }
        XCTAssertEqual(rows.count, 2)

        try s.press(try XCTUnwrap(rows.last).label)
        XCTAssertEqual(Array(s.texts.prefix(2)), ["Gears", "Printing"])
        XCTAssertEqual(h.model.settings.focusId, PrinterSettings.p1s().serial, "the menu bar follows the click")
    }

    func testOnePrinterHasNoList() throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(.x2d()).first)
        link.accept()
        link.report(Report.state("IDLE"))
        let s = try panel(h)
        XCTAssertEqual(s.texts, ["X2D", "Idle"])
        XCTAssertEqual(s.controls.map(\.label), ["More"])
    }

    // MARK: - History

    private func historyRow(_ i: Int, serial: String = "x2d", outcome: String? = JobLog.outcomeOK, job: String? = "Benchy") -> JobLogRow {
        let start = Rows.now - Double(i + 1) * 3 * 3600
        return JobLogRow(
            serial: serial,
            name: serial.uppercased(),
            jobId: "t\(i)",
            job: job,
            filament: "PLA",
            startAt: start,
            endedAt: outcome == nil ? nil : start + 2 * 3600 + 300,
            outcome: outcome
        )
    }

    func testEmptyHistory() throws {
        var closed = 0
        let s = try Screen(HistoryView(rows: [], now: Rows.now, onExport: {}, onClose: { closed += 1 }))
        assertReadsWell(s)
        XCTAssertEqual(s.texts, ["History", "No prints on this Mac yet."])
        XCTAssertFalse(try s.control("Export CSV").enabled)
        try s.press("Back")
        XCTAssertEqual(closed, 1)
    }

    func testHistoryRowsSayHowEachPrintEnded() throws {
        var exported = 0
        let rows = [historyRow(0, outcome: nil), historyRow(1, outcome: JobLog.outcomeFail, job: nil), historyRow(2)]
        let s = try Screen(HistoryView(rows: rows, now: Rows.now, onExport: { exported += 1 }, onClose: {}))
        // Each row reads as one element: "<job or printer>, <started> · <took> · <outcome>".
        let read = Array(s.texts.dropFirst())
        XCTAssertEqual(read.count, 3)
        XCTAssertTrue(read[0].hasPrefix("Benchy, ") && read[0].hasSuffix(" · Printing"), read[0])
        XCTAssertTrue(read[1].hasPrefix("X2D, ") && read[1].hasSuffix(" · 2h 05m · Failed"), "no job name: the printer's; \(read[1])")
        XCTAssertTrue(read[2].hasPrefix("Benchy, ") && read[2].hasSuffix(" · 2h 05m · Finished"), read[2])
        XCTAssertFalse(read[2].contains("X2D"), "one printer, so rows don't name it")
        try s.press("Export CSV")
        XCTAssertEqual(exported, 1)
    }

    func testHistoryNamesThePrinterWhenThereAreSeveral() throws {
        let s = try Screen(HistoryView(rows: [historyRow(0), historyRow(1, serial: "p1s")], now: Rows.now, onExport: {}, onClose: {}))
        XCTAssertTrue(s.texts.contains { $0.hasPrefix("Benchy, X2D · ") }, "\(s.texts)")
        XCTAssertTrue(s.texts.contains { $0.hasPrefix("Benchy, P1S · ") })
    }
}
