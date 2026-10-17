import Foundation
import XCTest
@testable import PrintGlance

final class ParserParityTests: XCTestCase {
    func testAppMatchesTheSharedParserFixture() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "parser-parity", withExtension: "json", subdirectory: "Fixtures")
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let printObj = try XCTUnwrap(item["print"] as? [String: Any], "\(id) has no print object")
            if let job = item["job"] as? String {
                XCTAssertEqual(
                    BambuPrint.jobLabel(printObj),
                    job,
                    "\(id): BambuPrint.jobLabel in Sources/PrintGlance/BambuSnapshot.swift is the source of truth. Update bambu.job_label to match it."
                )
            }
            if let filament = item["filament"] as? String {
                XCTAssertEqual(
                    BambuPrint.activeFilament(printObj).type,
                    filament,
                    "\(id): BambuPrint.activeFilament is the source of truth. Update bambu.active_filament and bambu._find_ams_tray to match it."
                )
            }
            if let remaining = BambuJSON.intValue(item["remainingS"]) {
                let row = BambuPrint.row(id: "x", name: "X", printObj: printObj, online: true)
                XCTAssertEqual(
                    row.remainingS,
                    remaining,
                    "\(id): BambuPrint.row caps remaining time at 30 days. Update bambu.printer_row to use MAX_REMAINING_MIN."
                )
            }
        }
    }
}
