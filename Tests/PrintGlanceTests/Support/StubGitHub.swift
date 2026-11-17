import Foundation

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
