import Foundation

struct PrintFeed: Sendable {
    var printURL: URL
    var token: String
    var session: URLSession

    static let defaultPrintURL = URL(string: "http://127.0.0.1:8080/print.json")!

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1
        c.timeoutIntervalForResource = 1
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    init(
        printURL: URL = PrintFeed.defaultPrintURL,
        token: String = UserDefaults.standard.string(forKey: "feedToken") ?? "",
        session: URLSession = PrintFeed.makeSession()
    ) {
        self.printURL = printURL
        self.token = token
        self.session = session
    }

    /// Maps an HTTP response to a feed result. Non-2xx bodies are never decoded as v1.
    static func interpret(status: Int, data: Data) -> FeedResult {
        if status == 401 {
            return .unauthorized
        }
        guard (200 ..< 300).contains(status) else {
            return .http(status)
        }
        do {
            let doc = try JSONCoding.decoder.decode(PrintDoc.self, from: data)
            guard doc.v == 1 else {
                return .invalid
            }
            return .doc(doc)
        } catch {
            return .invalid
        }
    }

    func fetchRaw() async -> (Int, Data)? {
        var req = URLRequest(url: printURL, timeoutInterval: 1)
        if !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Stats-Token")
        }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code, data)
        } catch {
            return nil
        }
    }
}
