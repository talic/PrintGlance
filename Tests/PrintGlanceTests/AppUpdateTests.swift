import Foundation
import XCTest
@testable import PrintGlance

final class AppUpdateTests: XCTestCase {
    func testRemoteTagNewerThanLocal() {
        XCTAssertTrue(AppUpdate.isNewer("v1.0.3", than: "1.0.2"))
        XCTAssertTrue(AppUpdate.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(AppUpdate.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertFalse(AppUpdate.isNewer("v1.0.2", than: "1.0.2"))
        XCTAssertFalse(AppUpdate.isNewer("1.0.2", than: "1.0.3"))
        XCTAssertFalse(AppUpdate.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppUpdate.isNewer("v1.0.0", than: "1.0"))
        XCTAssertFalse(AppUpdate.isNewer("", than: "1.0.2"))
        XCTAssertFalse(AppUpdate.isNewer("nope", than: "1.0.2"))
        XCTAssertFalse(AppUpdate.isNewer("v1.0.3", than: "bogus"))
    }

    func testCheckIsDueAfterADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AppUpdate.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(AppUpdate.isDue(
            lastCheck: now.addingTimeInterval(-23 * 3600),
            now: now
        ))
        XCTAssertTrue(AppUpdate.isDue(
            lastCheck: now.addingTimeInterval(-24 * 3600),
            now: now
        ))
    }

    func testTagFromGitHubLatestJSON() {
        let data = Data(#"{"tag_name":"v1.0.3","name":"v1.0.3"}"#.utf8)
        XCTAssertEqual(AppUpdate.tag(fromAPIJSON: data), "v1.0.3")
        XCTAssertNil(AppUpdate.tag(fromAPIJSON: Data(#"{"name":"v1.0.3"}"#.utf8)))
        XCTAssertNil(AppUpdate.tag(fromAPIJSON: Data("{}".utf8)))
        XCTAssertNil(AppUpdate.tag(fromAPIJSON: Data("not-json".utf8)))
    }
}
