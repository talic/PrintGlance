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

    func testZipURLFromGitHubLatestJSON() {
        func zip(_ assets: String) -> String? {
            AppUpdate.zipURL(fromAPIJSON: Data(#"{"tag_name":"v1.2.0","assets":[\#(assets)]}"#.utf8))?.absoluteString
        }
        let release = "https://github.com/talic/PrintGlance/releases/download/v1.2.0"
        XCTAssertEqual(
            zip(#"{"name":"notes.txt","browser_download_url":"\#(release)/notes.txt"},{"name":"PrintGlance.zip","browser_download_url":"\#(release)/PrintGlance.zip"}"#),
            "\(release)/PrintGlance.zip"
        )
        XCTAssertNil(zip(""), "release without assets yet")
        XCTAssertNil(zip(#"{"name":"Other.zip","browser_download_url":"\#(release)/Other.zip"}"#))
        XCTAssertNil(zip(#"{"name":"PrintGlance.zip","browser_download_url":"http://github.com/x/PrintGlance.zip"}"#))
        XCTAssertNil(zip(#"{"name":"PrintGlance.zip","browser_download_url":"https://example.com/PrintGlance.zip"}"#))
        XCTAssertNil(zip(#"{"name":"PrintGlance.zip"}"#))
        XCTAssertNil(AppUpdate.zipURL(fromAPIJSON: Data(#"{"tag_name":"v1.2.0"}"#.utf8)))
        XCTAssertNil(AppUpdate.zipURL(fromAPIJSON: Data("not-json".utf8)))
    }

    @MainActor
    func testDownloadOpensTheZipElseTheReleasePage() throws {
        let name = "PrintGlance.update.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let checker = AppUpdateChecker(defaults: d, localVersion: "1.0.0", session: URLSession(configuration: .ephemeral))
        XCTAssertEqual(checker.downloadURL, AppUpdate.latestReleaseURL)
        let zip = "https://github.com/talic/PrintGlance/releases/download/v1.2.0/PrintGlance.zip"
        d.set(zip, forKey: AppUpdateChecker.remoteZipKey)
        XCTAssertEqual(checker.downloadURL.absoluteString, zip)
    }
}
