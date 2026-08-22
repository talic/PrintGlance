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

    private func ams(
        now: Int,
        trays: [(Int, String, Int?)],
        vt: [String: Any]? = nil
    ) -> [String: Any] {
        var obj: [String: Any] = [
            "ams": [
                "tray_now": now,
                "ams": [[
                    "id": "0",
                    "tray": trays.map { id, type, remain -> [String: Any] in
                        var tray: [String: Any] = ["id": String(id), "tray_type": type]
                        if let remain { tray["remain"] = remain }
                        return tray
                    },
                ]],
            ]
        ]
        if let vt { obj["vt_tray"] = vt }
        return obj
    }
}
