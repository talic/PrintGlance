import Foundation
import XCTest
@testable import PrintGlance

final class PrepareAmsHmsTests: XCTestCase {
    func testPrepareStages() {
        XCTAssertEqual(label(2), "Heating")
        XCTAssertEqual(label(1), "Leveling")
        XCTAssertEqual(label(24), "Loading filament")
        XCTAssertEqual(label(22), "Unloading filament")
        XCTAssertEqual(label(99), "Starting")
        XCTAssertEqual(
            BambuPrint.stageLabel(state: "PREPARE", printObj: [:]),
            "Starting"
        )
        XCTAssertNil(
            BambuPrint.stageLabel(
                state: "RUNNING",
                printObj: ["stg_cur": 0]
            )
        )
    }

    func testPrepareStripUsesStageNotPercent() {
        var row = Printer(id: "x2d", name: "X2D", state: "PREPARE", percent: 0)
        row.stage = "Heating"
        row.eta = "14:32"
        let strip = GlanceContent.strip(row: row)
        XCTAssertEqual(strip.title, "Heating")
        XCTAssertEqual(strip.systemImage, "printer.fill")
    }

    func testTraysAndExternal() throws {
        let printObj: [String: Any] = [
            "gcode_state": "IDLE",
            "ams": [
                "ams": [[
                    "id": "0",
                    "humidity": "2",
                    "tray": [
                        [
                            "id": "0",
                            "tray_type": "PLA",
                            "tray_info_idx": "GFA01",
                            "remain": 80,
                            "tray_color": "F5C6A0FF",
                        ],
                        ["id": "1", "tray_type": "PLA", "remain": 10],
                        ["id": "2"],
                        [
                            "id": "3",
                            "tray_type": "PETG",
                            "remain": 40,
                        ],
                    ],
                ]],
            ],
            "vt_tray": [
                "tray_type": "ABS",
                "remain": 55,
                "tray_color": "000000FF",
            ],
        ]
        let row = BambuPrint.row(id: "x2d", name: "X2D", printObj: printObj, online: true)
        XCTAssertEqual(row.humidity, 2)
        let trays = try XCTUnwrap(row.trays)
        XCTAssertEqual(trays.map(\.id), ["0", "1", "3", "ext"])
        XCTAssertEqual(trays[0].name, "PLA Matte")
        XCTAssertEqual(trays[0].remain, 80)
        XCTAssertEqual(trays[0].color, "F5C6A0FF")
        XCTAssertEqual(trays.last?.id, "ext")
        XCTAssertEqual(trays.last?.name, "ABS")
        XCTAssertEqual(trays.last?.remain, 55)
    }

    func testHMSCodeOnFailBody() {
        let printObj: [String: Any] = [
            "gcode_state": "FAILED",
            "subtask_name": "Print in Parts",
            "hms": [[
                "attr": 0x0300_0000,
                "code": 0x0100_0001,
            ]],
        ]
        let row = BambuPrint.row(id: "x2d", name: "X2D", printObj: printObj, online: true)
        XCTAssertEqual(row.hmsCode, "0300-0000-0100-0001")

        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        _ = n.observe(GlanceContent(result: .doc(PrintDoc(
            v: 1,
            updatedAt: nil,
            focusId: "x2d",
            printers: [Printer(id: "x2d", name: "X2D", state: "RUNNING", job: "Print in Parts", jobId: "t1")]
        ))))
        var failed = row
        failed.jobId = "t1"
        failed.job = "Print in Parts"
        let out = n.observe(GlanceContent(result: .doc(PrintDoc(
            v: 1,
            updatedAt: nil,
            focusId: "x2d",
            printers: [failed]
        ))))
        XCTAssertEqual(out.alert?.kind, .fail)
        XCTAssertEqual(out.alert?.body, "Print in Parts on X2D · HMS 0300-0000-0100-0001")
    }

    func testFailWithoutHMSUnchanged() {
        var n = PrintNotify(serial: "x2d", prefs: .default, stamp: nil)
        _ = n.observe(GlanceContent(result: .doc(PrintDoc(
            v: 1,
            updatedAt: nil,
            focusId: "x2d",
            printers: [Printer(id: "x2d", name: "X2D", state: "RUNNING", job: "Print in Parts", jobId: "t1")]
        ))))
        let out = n.observe(GlanceContent(result: .doc(PrintDoc(
            v: 1,
            updatedAt: nil,
            focusId: "x2d",
            printers: [Printer(
                id: "x2d",
                name: "X2D",
                state: "FAILED",
                job: "Print in Parts",
                jobId: "t1"
            )]
        ))))
        XCTAssertEqual(out.alert?.body, "Print in Parts on X2D")
    }

    private func label(_ stg: Int) -> String? {
        BambuPrint.stageLabel(state: "PREPARE", printObj: ["stg_cur": stg])
    }
}
