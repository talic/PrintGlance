import Foundation

enum AppUpdate {
    static let day: TimeInterval = 24 * 60 * 60
    static let latestReleaseURL = URL(string: "https://github.com/talic/PrintGlance/releases/latest")!
    static let latestAPIURL = URL(string: "https://api.github.com/repos/talic/PrintGlance/releases/latest")!

    static var bundledVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True if `remote` is a higher dotted version than `local`. A leading `v` is ignored.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = numbers(remote)
        let l = numbers(local)
        guard !r.isEmpty, !l.isEmpty else { return false }
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = day) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static func tag(fromAPIJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func numbers(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" {
            s.removeFirst()
        }
        let parts = s.split(separator: ".")
        guard !parts.isEmpty else { return [] }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return [] }
            out.append(n)
        }
        return out
    }
}

@MainActor
final class AppUpdateChecker {
    static let lastCheckKey = "pg.update.lastCheck"
    static let remoteTagKey = "pg.update.remoteTag"

    private let defaults: UserDefaults
    private let localVersion: String
    private let session: URLSession
    private var loop: Task<Void, Never>?
    var onAvailable: ((String?) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        localVersion: String = AppUpdate.bundledVersion,
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        self.localVersion = localVersion
        self.session = session ?? Self.makeSession(localVersion: localVersion)
    }

    static func makeSession(localVersion: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "PrintGlance/\(localVersion) (+https://github.com/talic/PrintGlance)",
            "Accept": "application/vnd.github+json",
        ]
        return URLSession(configuration: config)
    }

    func start() {
        publishCached()
        loop?.cancel()
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkIfDue() async {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard AppUpdate.isDue(lastCheck: last, now: Date()) else {
            publishCached()
            return
        }
        await fetch()
    }

    private func fetch() async {
        var request = URLRequest(url: AppUpdate.latestAPIURL)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let tag = AppUpdate.tag(fromAPIJSON: data)
        else {
            publishCached()
            return
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        defaults.set(tag, forKey: Self.remoteTagKey)
        publish(tag)
    }

    private func publishCached() {
        publish(defaults.string(forKey: Self.remoteTagKey))
    }

    private func publish(_ tag: String?) {
        if let tag, AppUpdate.isNewer(tag, than: localVersion) {
            onAvailable?(tag)
        } else {
            onAvailable?(nil)
        }
    }
}
