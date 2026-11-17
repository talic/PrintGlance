import Foundation
import XCTest
@testable import PrintGlance

/// The daily GitHub check, the app's only request to the internet, against a stubbed GitHub.
@MainActor
final class UpdateCheckTests: XCTestCase {
    private let release = #"{"tag_name":"v9.9.9","assets":[{"name":"PrintGlance.zip","browser_download_url":"https://github.com/talic/PrintGlance/releases/download/v9.9.9/PrintGlance.zip"}]}"#

    override func tearDown() {
        StubGitHub.reset()
        super.tearDown()
    }

    private func checker(_ d: UserDefaults, version: String = "1.3.0") -> (AppUpdateChecker, () -> [String?]) {
        let checker = AppUpdateChecker(defaults: d, localVersion: version, session: StubGitHub.session())
        var published: [String?] = []
        checker.onAvailable = { published.append($0) }
        return (checker, { published })
    }

    func testNewerReleaseIsOfferedWithItsZip() async throws {
        let d = scratchDefaults()
        StubGitHub.reply(200, release)
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        XCTAssertEqual(published(), ["v9.9.9"])
        XCTAssertEqual(StubGitHub.requests.map(\.url), [AppUpdate.latestAPIURL])
        XCTAssertEqual(StubGitHub.requests.first?.httpMethod, "GET")
        XCTAssertEqual(checker.downloadURL.absoluteString, "https://github.com/talic/PrintGlance/releases/download/v9.9.9/PrintGlance.zip")
        XCTAssertNotNil(d.object(forKey: AppUpdateChecker.lastCheckKey))
    }

    func testSameVersionOffersNothing() async {
        let d = scratchDefaults()
        StubGitHub.reply(200, #"{"tag_name":"v1.3.0"}"#)
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        XCTAssertEqual(published(), [nil])
        XCTAssertEqual(checker.downloadURL, AppUpdate.latestReleaseURL, "no zip saved: the release page")
    }

    func testChecksAtMostOnceADay() async {
        let d = scratchDefaults()
        StubGitHub.reply(200, release)
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        await checker.checkIfDue()
        XCTAssertEqual(StubGitHub.requests.count, 1)
        XCTAssertEqual(published(), ["v9.9.9", "v9.9.9"], "the second check repeats what it knew")
    }

    func testFailedCheckKeepsTheLastAnswerAndRetriesLater() async {
        let d = scratchDefaults()
        d.set("v2.0.0", forKey: AppUpdateChecker.remoteTagKey)
        for (status, body) in [(500, "oops"), (200, "not json"), (200, #"{"tag_name":"  "}"#), (403, release)] {
            StubGitHub.reply(status, body)
            let (checker, published) = checker(d)
            await checker.checkIfDue()
            XCTAssertEqual(published(), ["v2.0.0"], "\(status) \(body)")
        }
        XCTAssertNil(d.object(forKey: AppUpdateChecker.lastCheckKey), "a failure doesn't count as today's check")
        XCTAssertEqual(StubGitHub.requests.count, 4)
    }

    func testCheckNowAsksAgainTheSameDay() async {
        let d = scratchDefaults()
        StubGitHub.reply(200, #"{"tag_name":"v1.3.0"}"#)
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        StubGitHub.reply(200, release)
        let answered = await checker.checkNow()
        XCTAssertTrue(answered)
        XCTAssertEqual(StubGitHub.requests.count, 2, "a click doesn't wait for tomorrow")
        XCTAssertEqual(published(), [nil, "v9.9.9"])
        XCTAssertEqual(checker.downloadURL.absoluteString, "https://github.com/talic/PrintGlance/releases/download/v9.9.9/PrintGlance.zip")
    }

    func testCheckNowSaysWhenGitHubDidNotAnswer() async {
        let d = scratchDefaults()
        d.set("v2.0.0", forKey: AppUpdateChecker.remoteTagKey)
        for (status, body) in [(500, "oops"), (403, release)] {
            StubGitHub.reply(status, body)
            let (checker, published) = checker(d)
            let answered = await checker.checkNow()
            XCTAssertFalse(answered, "\(status)")
            XCTAssertEqual(published(), ["v2.0.0"], "it still offers what it knew")
        }
        StubGitHub.reset()
        let answered = await checker(d).0.checkNow()
        XCTAssertFalse(answered, "offline")
        XCTAssertNil(d.object(forKey: AppUpdateChecker.lastCheckKey))
    }

    func testOfflineMacOffersWhatItKnew() async {
        let d = scratchDefaults()
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        XCTAssertEqual(published(), [nil])
    }
}
