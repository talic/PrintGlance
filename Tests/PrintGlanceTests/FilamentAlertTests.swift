import XCTest
@testable import PrintGlance

final class FilamentAlertTests: XCTestCase {
    func testLowFilamentWarning() {
        let unknown = BambuPrint.activeFilament(
            ams(now: 1, trays: [(0, "ABS", 5), (1, "PLA", -1)])
        )
        XCTAssertEqual(unknown.type, "PLA")
        XCTAssertNil(unknown.remain)
        XCTAssertEqual(unknown.tray, 1)

        var idle = Printer(id: "x2d", name: "X2D", state: "RUNNING")
        idle.filament = "PLA"
        XCTAssertEqual(GlanceContent.filamentLine(idle), "PLA")
        idle.filamentRemain = 0
        XCTAssertEqual(GlanceContent.filamentLine(idle), "PLA  0%")

        let ext = BambuPrint.activeFilament(
            ams(now: 254, trays: [(0, "ABS", 5)], vt: ["tray_type": "PETG", "remain": 15])
        )
        XCTAssertEqual(ext.type, "PETG")
        XCTAssertEqual(ext.remain, 15)
        XCTAssertEqual(ext.tray, 254)

        var alert = FilamentAlert()
        let unused = BambuPrint.activeFilament(
            ams(now: 1, trays: [(0, "ABS", 5), (1, "PLA", 42)])
        )
        XCTAssertEqual(unused.tray, 1)
        XCTAssertEqual(unused.remain, 42)
        XCTAssertNil(
            alert.consider(
                serial: "x2d",
                name: "X2D",
                state: "RUNNING",
                filament: unused.type,
                tray: unused.tray,
                remain: unused.remain,
                taskId: "task-1"
            )
        )

        XCTAssertNil(
            alert.consider(
                serial: "x2d",
                name: "X2D",
                state: "RUNNING",
                filament: unknown.type,
                tray: unknown.tray,
                remain: unknown.remain,
                taskId: "task-1"
            )
        )

        let first = alert.consider(
            serial: "x2d",
            name: "X2D",
            state: "RUNNING",
            filament: ext.type,
            tray: ext.tray,
            remain: ext.remain,
            taskId: "task-1"
        )
        XCTAssertEqual(first?.title, "Low filament")
        XCTAssertEqual(first?.body, "X2D is using PETG at 15%.")
        XCTAssertEqual(first?.identifier, "filament.x2d|254|task-1")

        XCTAssertNil(
            alert.consider(
                serial: "x2d",
                name: "X2D",
                state: "RUNNING",
                filament: ext.type,
                tray: ext.tray,
                remain: 10,
                taskId: "task-1"
            )
        )

        XCTAssertEqual(
            BambuPrint.taskId(["subtask_id": "sub-9"]),
            "sub-9"
        )
        XCTAssertEqual(
            BambuPrint.taskId(["task_id": "task-1", "subtask_id": "sub-9"]),
            "task-1"
        )
    }

    func testFilamentNameFromSkuAndSubBrand() {
        let pure = BambuPrint.activeFilament(
            ams(
                now: 0,
                trays: [(0, "PLA", 42)],
                extra: ["tray_info_idx": "GFA19", "tray_sub_brands": ""]
            )
        )
        XCTAssertEqual(pure.type, "PLA Pure")
        XCTAssertEqual(pure.remain, 42)

        let matte = BambuPrint.activeFilament(
            ams(now: 1, trays: [(1, "PLA", 80)], extra: ["tray_info_idx": "GFA01"])
        )
        XCTAssertEqual(matte.type, "PLA Matte")

        let named = BambuPrint.activeFilament(
            ams(
                now: 0,
                trays: [(0, "PLA", 10)],
                extra: ["tray_sub_brands": "PLA Pure", "tray_info_idx": "GFL99"]
            )
        )
        XCTAssertEqual(named.type, "PLA Pure")

        let bambuPrefix = BambuPrint.activeFilament(
            ams(now: 0, trays: [(0, "PLA", 10)], extra: ["tray_sub_brands": "Bambu PLA Matte"])
        )
        XCTAssertEqual(bambuPrefix.type, "PLA Matte")

        let typeOnly = BambuPrint.activeFilament(
            ams(now: 0, trays: [(0, "PLA Matte", 10)])
        )
        XCTAssertEqual(typeOnly.type, "PLA Matte")

        let unknownIdx = BambuPrint.activeFilament(
            ams(now: 0, trays: [(0, "PLA", 10)], extra: ["tray_info_idx": "GFA99"])
        )
        XCTAssertEqual(unknownIdx.type, "PLA")

        var row = Printer(id: "x2d", name: "X2D", state: "RUNNING")
        row.filament = "PLA Pure"
        row.filamentRemain = 42
        XCTAssertEqual(GlanceContent.filamentLine(row), "PLA Pure  42%")
    }

    func testFilamentColorFromTray() {
        XCTAssertEqual(BambuPrint.normalizeFilamentColor("ffffffff"), "FFFFFFFF")
        XCTAssertEqual(BambuPrint.normalizeFilamentColor("#00FF00"), "00FF00FF")
        XCTAssertNil(BambuPrint.normalizeFilamentColor("red"))
        XCTAssertNil(BambuPrint.normalizeFilamentColor("FFFFFF00"))

        let hex = BambuPrint.activeFilament(
            ams(now: 0, trays: [(0, "PLA", 42)], extra: ["tray_color": "F5C6A0FF"])
        )
        XCTAssertEqual(hex.color, "F5C6A0FF")

        let fromCols = BambuPrint.activeFilament(
            ams(now: 0, trays: [(0, "PLA", 42)], extra: ["cols": ["000000FF", "FFFFFFFF"]])
        )
        XCTAssertEqual(fromCols.color, "000000FF")

        let none = BambuPrint.activeFilament(ams(now: 0, trays: [(0, "PLA", 42)]))
        XCTAssertNil(none.color)

        let row = BambuPrint.row(
            id: "x2d",
            name: "X2D",
            printObj: [
                "gcode_state": "IDLE",
                "ams": [
                    "tray_now": 0,
                    "ams": [[
                        "id": "0",
                        "tray": [[
                            "id": "0",
                            "tray_type": "PLA",
                            "tray_info_idx": "GFA19",
                            "tray_color": "F5C6A0FF",
                        ]],
                    ]],
                ],
            ],
            online: true
        )
        XCTAssertEqual(row.filament, "PLA Pure")
        XCTAssertEqual(row.filamentColor, "F5C6A0FF")
    }

    private func ams(
        now: Int,
        trays: [(Int, String, Int?)],
        vt: [String: Any]? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var obj: [String: Any] = [
            "ams": [
                "tray_now": now,
                "ams": [[
                    "id": "0",
                    "tray": trays.map { id, type, remain -> [String: Any] in
                        var tray: [String: Any] = ["id": String(id), "tray_type": type]
                        if let remain { tray["remain"] = remain }
                        for (k, v) in extra { tray[k] = v }
                        return tray
                    },
                ]],
            ]
        ]
        if let vt { obj["vt_tray"] = vt }
        return obj
    }
}
