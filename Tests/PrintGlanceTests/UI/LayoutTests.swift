import SwiftUI
import XCTest
@testable import PrintGlance

/// Size limits the menu bar panel and setup window rely on. The panel sizes itself to the card
/// (`hugMenuBarPanel`), so a card that grows without bound would run off the screen.
@MainActor
final class LayoutTests: XCTestCase {
    /// A 1280×800 display, the smallest a supported Mac shows by default, minus the menu bar.
    private let smallScreenHeight: CGFloat = 800 - 24

    func testTallestPanelFitsASmallDisplay() throws {
        let h = ModelHarness(self)
        let links = h.add(.x2d(), .p1s(), PrinterSettings(ip: "192.0.2.12", serial: "0309DA123456789", accessCode: "a", name: "A1 mini"),
                          PrinterSettings(ip: "192.0.2.13", serial: "22E8BJ5A2900042", accessCode: "b", name: "H2D"))
        links.forEach { $0.accept() }
        links[0].report(["gcode_state": "IDLE"].merging(Rows.fullAMS))
        let height = try Screen(GlanceView(model: h.model)).size.height
        XCTAssertLessThanOrEqual(height, smallScreenHeight, "four AMS units, an AMS HT, two external spools, and four printers")
    }

    func testLongNamesTruncateInsteadOfGrowingTheCard() throws {
        for (label, row) in [("printing", Rows.printing()), ("idle", Rows.idle()), ("paused", Rows.paused()),
                             ("finished", Rows.finished()), ("failed", Rows.failed())] {
            var hostile = row
            hostile.name = String(repeating: "Garage printer ", count: 20)
            hostile.job = row.job.map { _ in String(repeating: "Very long job ", count: 20) }
            hostile.filament = String(repeating: "Silk ", count: 40)
            let normal = try Screen(Rows.card(row)).size
            let grown = try Screen(Rows.card(hostile)).size
            XCTAssertEqual(grown.width, 248, label)
            XCTAssertEqual(grown.height, normal.height, accuracy: 1, "\(label): names stay on one line")
        }
    }

    func testListRowsStayOneLineEach() throws {
        var printers = (0..<4).map { i -> Printer in
            var p = Rows.printing()
            p.id = "p\(i)"
            p.name = "Printer \(i)"
            return p
        }
        let normal = try Screen(PrinterList(printers: printers, shownId: nil, onSelect: { _ in }, onEdit: { _ in }, onRemove: { _ in }).frame(width: 220)).size
        printers[2].name = String(repeating: "Garage ", count: 30)
        let grown = try Screen(PrinterList(printers: printers, shownId: nil, onSelect: { _ in }, onEdit: { _ in }, onRemove: { _ in }).frame(width: 220)).size
        XCTAssertEqual(grown.height, normal.height, accuracy: 1)
    }

    func testMenuBarTitleKeepsItsWidthAsThePercentGrows() throws {
        func width(_ percent: Int) throws -> CGFloat {
            var row = Rows.printing()
            row.percent = percent
            return try Screen(StripLabel(strip: GlanceContent.strip(row: row))).size.width
        }
        let one = try width(5)
        XCTAssertEqual(try width(52), one, accuracy: 0.5, "figure spaces pad to the width of a digit")
        XCTAssertEqual(try width(100), one, accuracy: 0.5)
    }

    func testHistoryScrollsInsteadOfGrowing() throws {
        let rows = (0..<JobLog.cap).map { i in
            JobLogRow(serial: i % 2 == 0 ? "x2d" : "p1s", name: "X2D", jobId: "t\(i)", job: "Job \(i)", filament: nil,
                      startAt: Rows.now - Double(i) * 3600, endedAt: Rows.now - Double(i) * 3600 + 1800, outcome: JobLog.outcomeOK)
        }
        let size = try Screen(HistoryView(rows: rows, now: Rows.now, onExport: {}, onClose: {})).size
        XCTAssertEqual(size.width, 248)
        XCTAssertLessThanOrEqual(size.height, 360 + 80, "a 360 pt scroll area plus the title row and padding")
    }

    func testSetupWindowWrapsLongMessages() throws {
        let f = SetupFlow(mode: .add, saved: .empty)
        f.manual = true
        f.phase = .failed(String(repeating: "The printer refused the connection. ", count: 6))
        XCTAssertEqual(try Screen(SetupView(flow: f)).size.width, 360)
    }
}
