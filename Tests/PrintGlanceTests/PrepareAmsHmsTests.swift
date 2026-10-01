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
        XCTAssertEqual(trays.map(\.label), ["A1", "A2", "A4", "External"])
        XCTAssertEqual(trays.map(\.unit), ["A", "A", "A", nil])
        XCTAssertEqual(trays[0].name, "PLA Matte")
        XCTAssertEqual(trays[0].remain, 80)
        XCTAssertEqual(trays[0].color, "F5C6A0FF")
        XCTAssertEqual(trays.last?.name, "ABS")
        XCTAssertEqual(trays.last?.remain, 55)
        XCTAssertEqual(GlanceContent.trayLine(trays[0]), "A1 · PLA Matte  80%")
        XCTAssertEqual(GlanceContent.trayLine(trays[3]), "External · ABS  55%")

        let groups = GlanceContent.amsGroups(row)
        XCTAssertEqual(groups.map(\.header), ["AMS A · Humid", nil])
        XCTAssertEqual(groups.map { $0.trays.count }, [3, 1])
    }

    func testTwoAMSAndHTAndDualExternal() throws {
        let tray: [String: Any] = ["id": "0", "tray_type": "PLA", "remain": 50]
        let printObj: [String: Any] = [
            "gcode_state": "IDLE",
            "ams": ["ams": [
                ["id": "0", "info": "1001", "humidity": "5", "tray": [tray, ["id": "3", "tray_type": "PETG"]]],
                ["id": "1", "info": "1003", "humidity": "4", "humidity_raw": "23", "tray": [tray]],
                ["id": "128", "info": "4", "humidity": "3", "humidity_raw": "45", "tray": [tray]],
            ]],
            "vir_slot": [
                ["id": "255", "tray_type": "TPU"],
                ["id": "254", "tray_type": "PLA"],
            ],
            "vt_tray": ["id": "254", "tray_type": "ignored"],
        ]
        let row = BambuPrint.row(id: "h2d", name: "H2D", printObj: printObj, online: true)
        let trays = try XCTUnwrap(row.trays)
        XCTAssertEqual(trays.map(\.label), ["A1", "A4", "B1", "HT-A", "External R", "External L"])
        XCTAssertEqual(trays.map(\.id), ["0", "3", "4", "128", "255", "254"])
        XCTAssertEqual(row.amsUnits?.map(\.id), ["A", "B", "HT-A"])
        XCTAssertEqual(row.amsUnits?.map(\.humidityPercent), [nil, 23, 45], "percent only from AMS 2 Pro and HT")
        XCTAssertEqual(
            GlanceContent.amsGroups(row).map(\.header),
            ["AMS A · Dry", "AMS B · 23%", "AMS HT-A · 45%", nil]
        )

        var single = printObj
        single["vir_slot"] = nil
        let one = BambuPrint.row(id: "x2d", name: "X2D", printObj: single, online: true)
        XCTAssertEqual(one.trays?.last?.label, "External")
        XCTAssertEqual(one.trays?.last?.name, "ignored")
    }

    func testOneAMSWithoutHumidityHasNoHeader() {
        var row = Printer(id: "a1", name: "A1", state: "IDLE")
        row.trays = [AMSTray(id: "0", name: "PLA", remain: nil, color: nil, label: "A1", unit: "A")]
        row.amsUnits = [AMSUnit(id: "A")]
        XCTAssertEqual(GlanceContent.amsGroups(row), [AMSGroup(header: nil, trays: row.trays!)])
        XCTAssertEqual(GlanceContent.trayLine(row.trays![0]), "A1 · PLA")
    }

    func testHumidityWords() {
        XCTAssertEqual((1...5).map { GlanceContent.humidityText(AMSUnit(id: "A", humidityLevel: $0)) },
                       ["Humid", "Humid", "OK", "Dry", "Dry"])
        XCTAssertEqual(GlanceContent.humidityText(AMSUnit(id: "A", humidityLevel: 1, humidityPercent: 61)), "61%")
        XCTAssertNil(GlanceContent.humidityText(AMSUnit(id: "A")))
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

    func testHeatingUnderRunningIsStarting() {
        func row(_ printObj: [String: Any]) -> Printer {
            BambuPrint.row(id: "x2d", name: "X2D", printObj: printObj, online: true)
        }
        let heating: [String: Any] = [
            "gcode_state": "RUNNING", "stg_cur": 2, "layer_num": 0, "mc_percent": 0,
            "nozzle_temper": 186.5, "nozzle_target_temper": 220, "bed_temper": 48.2, "bed_target_temper": 60,
        ]
        let starting = row(heating)
        XCTAssertEqual(starting.state, "PREPARE")
        XCTAssertEqual(starting.stage, "Heating")
        XCTAssertEqual(starting.nozzleTemp, Temp(current: 186, target: 220))
        XCTAssertEqual(GlanceContent.heatLine(starting), "Nozzle 186 / 220° · Bed 48 / 60°")
        XCTAssertEqual(GlanceContent.strip(row: starting).title, "Heating")

        var noLayerYet = heating
        noLayerYet["layer_num"] = nil
        XCTAssertEqual(row(noLayerYet).state, "PREPARE", "a new job's layer arrives later")

        var printing = heating
        printing["stg_cur"] = 0
        printing["layer_num"] = 1
        XCTAssertEqual(row(printing).state, "RUNNING")
        XCTAssertNil(row(printing).nozzleTemp, "no temperatures while printing, so rows stay equal")

        var swap = heating
        swap["stg_cur"] = 4
        swap["layer_num"] = 37
        XCTAssertEqual(row(swap).state, "RUNNING", "a filament change mid-print is printing")

        var paused = heating
        paused["gcode_state"] = "PAUSE"
        XCTAssertEqual(row(paused).state, "PAUSE")
        XCTAssertNil(row(paused).nozzleTemp)

        XCTAssertEqual(row(["gcode_state": "PREPARE", "gcode_file_prepare_percent": "40"]).state, "PREPARE")
    }

    func testHeatLine() {
        var row = Printer(id: "x2d", name: "X2D", state: "PREPARE")
        XCTAssertNil(GlanceContent.heatLine(row))
        row.nozzleTemp = Temp(current: 45, target: 0)
        row.bedTemp = Temp(current: 48, target: 60)
        row.chamberTemp = Temp(current: 30, target: 0)
        XCTAssertEqual(GlanceContent.heatLine(row), "Nozzle 45° · Bed 48 / 60°", "chamber hidden while it isn't heating")
        row.chamberTemp = Temp(current: 31, target: 45)
        XCTAssertEqual(GlanceContent.heatLine(row), "Nozzle 45° · Bed 48 / 60° · Chamber 31 / 45°")
        row.state = "RUNNING"
        XCTAssertNil(GlanceContent.heatLine(row))
    }

    func testPackedTemperatures() {
        XCTAssertEqual(BambuPrint.packedTemp(14_418_140), Temp(current: 220, target: 220))
        XCTAssertEqual(BambuPrint.packedTemp(3_604_535), Temp(current: 55, target: 55))
        XCTAssertEqual(BambuPrint.packedTemp(45), Temp(current: 45, target: 0), "under 65536: no target")
        XCTAssertEqual(BambuPrint.packedTemp(186 | 220 << 16), Temp(current: 186, target: 220))
        XCTAssertNil(BambuPrint.packedTemp(-1))
        XCTAssertNil(BambuPrint.packedTemp(nil))
    }

    /// Values from a real X2D report: the left nozzle (id 1) is down at 220°, the other idles at 45°.
    func testDualNozzleReadsTheActiveNozzle() {
        var x2d: [String: Any] = [
            "nozzle_temper": 199.0,
            "nozzle_target_temper": 0.0,
            "bed_temper": 55.0,
            "bed_target_temper": 55.0,
            "device": [
                "extruder": [
                    "state": 33042,
                    "info": [["id": 0, "temp": 45], ["id": 1, "temp": 14_418_140]],
                ],
                "bed": ["info": ["temp": 3_604_535], "state": 2],
                "bed_temp": 3_604_535,
                "ctc": ["info": ["temp": 34], "state": 0],
            ],
        ]
        XCTAssertEqual(BambuPrint.nozzleTemp(x2d), Temp(current: 220, target: 220), "top-level nozzle ignored")
        XCTAssertEqual(BambuPrint.bedTemp(x2d), Temp(current: 55, target: 55))
        XCTAssertEqual(BambuPrint.chamberTemp(x2d), Temp(current: 34, target: 0))

        x2d["device"] = ["extruder": ["state": 2 | 0 << 4, "info": [["id": 1, "temp": 45], ["id": 0, "temp": 186 | 220 << 16]]]]
        XCTAssertEqual(BambuPrint.nozzleTemp(x2d), Temp(current: 186, target: 220), "matched by id, not position")
        XCTAssertEqual(BambuPrint.bedTemp(x2d), Temp(current: 55, target: 55), "top-level bed without a device block")
    }

    func testSingleNozzleReadsTopLevelFields() {
        let a1: [String: Any] = [
            "nozzle_temper": 186.9375,
            "nozzle_target_temper": 220,
            "bed_temper": 47.96875,
            "bed_target_temper": 60,
            "chamber_temper": 5,
        ]
        XCTAssertEqual(BambuPrint.nozzleTemp(a1), Temp(current: 186, target: 220), "cut off, not rounded")
        XCTAssertEqual(BambuPrint.bedTemp(a1), Temp(current: 47, target: 60))
        XCTAssertEqual(BambuPrint.chamberTemp(a1), Temp(current: 5, target: 0), "placeholder without a sensor")
        XCTAssertNil(BambuPrint.nozzleTemp([:]))

        let h2d: [String: Any] = ["chamber_temper": 49, "ctt": 60, "device": ["ctc": ["info": ["temp": 48 | 60 << 16]]]]
        XCTAssertEqual(BambuPrint.chamberTemp(h2d), Temp(current: 48, target: 60), "device.ctc wins, like Bambu Studio")
        XCTAssertEqual(BambuPrint.chamberTemp(["chamber_temper": 49, "ctt": 60]), Temp(current: 49, target: 60))
    }

    func testNestedObjectsMergeKeyByKey() {
        var dst: [String: Any] = [
            "gcode_state": "PREPARE",
            "device": [
                "bed": ["info": ["temp": 3_604_535]],
                "extruder": ["state": 33042, "info": [["id": 0, "temp": 45], ["id": 1, "temp": 100]]],
            ],
            "hms": [["attr": 1, "code": 2]],
        ]
        BambuPrint.merge(&dst, incoming: [
            "device": ["extruder": ["info": [["id": 1, "temp": 150 | 220 << 16]]]],
            "hms": [],
        ])
        XCTAssertEqual(BambuPrint.bedTemp(dst), Temp(current: 55, target: 55), "bed kept")
        let extruder = (dst["device"] as? [String: Any])?["extruder"] as? [String: Any]
        XCTAssertEqual(extruder?["state"] as? Int, 33042, "state kept")
        XCTAssertEqual((extruder?["info"] as? [Any])?.count, 1, "arrays are replaced whole")
        XCTAssertEqual((dst["hms"] as? [Any])?.count, 0)
        XCTAssertEqual(dst["gcode_state"] as? String, "PREPARE")
    }

    private func label(_ stg: Int) -> String? {
        BambuPrint.stageLabel(state: "PREPARE", printObj: ["stg_cur": stg])
    }
}
