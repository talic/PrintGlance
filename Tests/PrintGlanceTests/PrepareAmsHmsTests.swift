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

    func testHostileNumbersDoNotTrap() throws {
        let json = #"""
        {"gcode_state": "RUNNING", "mc_percent": 1e300, "mc_remaining_time": 9223372036854775807,
         "ams": {"ams": [{"id": 9223372036854775807,
                          "tray": [{"id": 9223372036854775807, "tray_type": "PLA", "remain": 50}]}]}}
        """#
        let printObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let row = BambuPrint.row(id: "x2d", name: "X2D", printObj: printObj, online: true)
        XCTAssertEqual(row.state, "RUNNING")
        XCTAssertNil(row.percent)
        XCTAssertEqual(row.remainingS, 43_200 * 60)
        XCTAssertEqual(row.trays?.count, 1)
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
        XCTAssertEqual(out.alert?.body, "Print in Parts on X2D · Error 0300-0000-0100-0001")
    }

    func testPrintErrorFormatsLikeBambuStudio() {
        XCTAssertEqual(BambuPrint.printErrorCode(117_473_282), "0700-8002")
        XCTAssertEqual(BambuPrint.printErrorCode("50348044"), "0300-400C")
        XCTAssertNil(BambuPrint.printErrorCode(0))
        XCTAssertNil(BambuPrint.printErrorCode(-1))
        XCTAssertNil(BambuPrint.printErrorCode(nil))
        let row = BambuPrint.row(
            id: "x2d",
            name: "X2D",
            printObj: ["gcode_state": "PAUSE", "print_error": 117_473_282],
            online: true
        )
        XCTAssertEqual(row.printError, "0700-8002")
    }

    func testErrorCodesOnlyWhenPausedOrFailed() {
        var row = Printer(id: "01P00A000000001", name: "P1S", state: "PAUSE", percent: 40)
        row.hmsCode = "0700-2000-0002-0001"
        row.printError = "0700-8002"
        XCTAssertEqual(GlanceContent.errorCodes(row), ["0700-2000-0002-0001", "0700-8002"])
        row.state = "FAILED"
        XCTAssertEqual(GlanceContent.errorCodes(row).count, 2)
        row.state = "RUNNING"
        XCTAssertEqual(GlanceContent.errorCodes(row), [], "print_error can linger after the problem is gone")
        row.state = "PAUSE"
        row.hmsCode = nil
        row.printError = nil
        XCTAssertEqual(GlanceContent.errorCodes(row), [])
    }

    func testErrorLookupURLs() {
        let hms = GlanceContent.errorLookup(code: "0700-2000-0002-0001", serial: "01P00A000000001")
        XCTAssertEqual(
            hms.url.absoluteString,
            "https://e.bambulab.com/index.php?e=0700200000020001&d=01P&s=device_hms&lang=en"
        )
        XCTAssertFalse(hms.copiesCode)
        let pe = GlanceContent.errorLookup(code: "0700-8002", serial: "01P00A000000001")
        XCTAssertEqual(pe.url.absoluteString, "https://wiki.bambulab.com/en/hms/error-code#:~:text=0700%2D8002")
        XCTAssertTrue(pe.copiesCode)
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
