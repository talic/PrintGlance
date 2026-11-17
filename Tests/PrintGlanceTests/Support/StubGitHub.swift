import Foundation

/// Answers every request with the canned reply, or fails as if offline.
final class StubGitHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: (status: Int, body: String)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var files: [URL: (status: Int, body: Data)] = [:]

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// A session whose every request reaches this stub, never the internet.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubGitHub.self]
        return URLSession(configuration: config)
    }

    static func reply(_ status: Int, _ body: String) {
        lock.lock()
        canned = (status, body)
        lock.unlock()
    }

    /// Answers requests for `url` with `body`, ahead of the canned reply: a release's downloads.
    static func serve(_ url: URL, status: Int = 200, _ body: Data) {
        lock.lock()
        files[url] = (status, body)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        canned = nil
        seen = []
        files = [:]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let reply = request.url.flatMap { Self.files[$0] } ?? Self.canned.map { (status: $0.status, body: Data($0.body.utf8)) }
        Self.lock.unlock()
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
