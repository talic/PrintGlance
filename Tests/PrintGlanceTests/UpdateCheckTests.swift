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
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubGitHub.self]
        let checker = AppUpdateChecker(defaults: d, localVersion: version, session: URLSession(configuration: config))
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

    func testOfflineMacOffersWhatItKnew() async {
        let d = scratchDefaults()
        let (checker, published) = checker(d)
        await checker.checkIfDue()
        XCTAssertEqual(published(), [nil])
    }
}

/// Answers every request with the canned reply, or fails as if offline.
final class StubGitHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: (status: Int, body: String)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func reply(_ status: Int, _ body: String) {
        lock.lock()
        canned = (status, body)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        canned = nil
        seen = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let reply = Self.canned
        Self.lock.unlock()
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
