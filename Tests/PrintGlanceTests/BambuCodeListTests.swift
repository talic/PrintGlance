import Foundation
import XCTest
@testable import PrintGlance

/// Bambu's own descriptions, for codes outside our table. The lists here are made up in a scratch folder,
/// laid out like the ones Bambu Studio keeps; `GlanceContent.bambuWords` is emptied again after each test.
final class BambuCodeListTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-codes-\(UUID().uuidString)")
        for sub in ["cloud", "local"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try write("cloud/hms_en_20P.json", """
        {"result":0,"t":1,"ver":2,"data":{"device_hms":{"ver":3,"en":[
          {"ecode":"0503000000030027","intro":""},
          {"ecode":"0500050000010007","intro":"The chamber heater is malfunctioning.\\nCaution: the nozzle is hot."}]},
        "device_error":{"en":[{"ecode":"07018010","intro":"The AMS motor is overloaded. "},
          {"ecode":"05024005","intro":"The AMS needs calibrating before it can print."}]}}}
        """)
        try write("local/hms_en_094.json", """
        {"data":{"device_hms":{"en":[
          {"ecode":"0500050000010007","intro":"An older description."},
          {"ecode":"0C00040000020003","intro":"The BirdsEye camera is dirty."},
          {"ecode":"1801200000020009","intro":""}]}}}
        """)
        try write("local/hms_de_094.json", """
        {"data":{"device_hms":{"de":[{"ecode":"0300000001000001","intro":"Nicht auf Englisch."}]}}}
        """)
    }

    override func tearDown() {
        GlanceContent.bambuWords.set([:])
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read() -> [String: String] {
        BambuCodeList.read(folders: ["cloud", "local", "missing"].map(dir.appendingPathComponent))
    }

    func testListsAreReadNewestFirstInEnglishOnly() {
        XCTAssertEqual(read(), [
            "0500050000010007": "The chamber heater is malfunctioning.",
            "07018010": "The AMS motor is overloaded.",
            "05024005": "The AMS needs calibrating before it can print.",
            "0C00040000020003": "The BirdsEye camera is dirty.",
            "0503000000030027": "",
            "1801200000020009": "",
        ])
    }

    func testBambusWordsFillInWhereOursStop() {
        typealias Line = GlanceContent.CodeLine
        XCTAssertNil(GlanceContent.errorReason(code: "0500-0500-0001-0007"), "nothing until the lists are read")
        GlanceContent.bambuWords.set(read())

        XCTAssertEqual(GlanceContent.errorReason(code: "0500-0500-0001-0007"), "The chamber heater is malfunctioning.")
        XCTAssertEqual(GlanceContent.errorReason(code: "0701-8010"), "The feed motor in AMS B is overloaded. A spool may be tangled or stuck.",
                       "our shorter words come first")
        XCTAssertEqual(GlanceContent.errorReason(code: "0c00-0400-0002-0003"), "The BirdsEye camera is dirty.")
        XCTAssertNil(GlanceContent.errorReason(code: "0503-0000-0003-0027"), "listed without a description")
        XCTAssertNil(GlanceContent.errorReason(code: "0300-0000-0100-0001"), "not listed in English")

        XCTAssertEqual(GlanceContent.errorLine(code: "0503-0000-0003-0027"),
                       "The printer sent a message Bambu doesn't describe. Its screen may say more.")
        XCTAssertEqual(GlanceContent.errorLine(code: "1801-2000-0002-0009"),
                       "The AMS sent a message Bambu doesn't describe. The printer's screen may say more.")
        XCTAssertEqual(GlanceContent.errorLine(code: "0300-0000-0100-0001"), "Error 0300-0000-0100-0001")

        var row = Printer(id: "x2d", name: "X2D", state: "FAILED")
        row.hmsCode = "0503-0000-0003-0027"
        XCTAssertEqual(GlanceContent.codeLines(row), [
            Line(reason: "The printer sent a message Bambu doesn't describe. Its screen may say more.", code: "0503-0000-0003-0027"),
        ], "still listed with Look up, under words")
        XCTAssertNil(GlanceContent.errorReason(row), "a code Bambu doesn't describe isn't a reason")
        XCTAssertEqual(GlanceContent.leadErrorCode(row), "0503-0000-0003-0027")

        row.printError = "0502-4005"
        XCTAssertEqual(GlanceContent.codeLines(row), [
            Line(reason: "The AMS needs calibrating before it can print.", code: "0502-4005"),
            Line(reason: "The printer sent a message Bambu doesn't describe. Its screen may say more.", code: "0503-0000-0003-0027"),
        ], "the described code leads, like the notification")
        XCTAssertEqual(GlanceContent.errorReason(row), "The AMS needs calibrating before it can print.")
        XCTAssertEqual(GlanceContent.leadErrorCode(row), "0502-4005")
    }
}
