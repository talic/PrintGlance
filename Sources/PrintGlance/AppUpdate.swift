import CryptoKit
import Foundation

enum AppUpdate {
    static let day: TimeInterval = 24 * 60 * 60
    static let latestReleaseURL = URL(string: "https://github.com/talic/PrintGlance/releases/latest")!
    static let latestAPIURL = URL(string: "https://api.github.com/repos/talic/PrintGlance/releases/latest")!

    /// The Ed25519 public key whose private half, in the owner's login Keychain, signs each release's
    /// `PrintGlance.zip` (`make sign-release`). A zip it didn't sign is never installed.
    static let signingKey = "zX56luKqts6FtjfJDSSaeB0oA3Ydoa8kAZhYzuKlKSY="
    static let zipName = "PrintGlance.zip"
    static let signatureName = "PrintGlance.zip.sig"
    /// A release zip is about 2 MB. Anything far bigger isn't one.
    static let maxDownload = 64 << 20

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

    /// The release's `PrintGlance.zip` download. Nil when the asset is missing or isn't a GitHub https link.
    static func zipURL(fromAPIJSON data: Data) -> URL? {
        assetURL(named: zipName, fromAPIJSON: data)
    }

    /// The zip's signature, `PrintGlance.zip.sig`. Nil like `zipURL`, and for releases before 1.6.
    static func signatureURL(fromAPIJSON data: Data) -> URL? {
        assetURL(named: signatureName, fromAPIJSON: data)
    }

    private static func assetURL(named name: String, fromAPIJSON data: Data) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == name }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              url.scheme == "https", url.host == "github.com"
        else { return nil }
        return url
    }

    /// True when `signature`, the base64 text `make sign-release` attaches, is `key`'s Ed25519
    /// signature of exactly these zip bytes.
    static func isSigned(_ zip: Data, signature: Data, key: String) -> Bool {
        guard let keyData = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return publicKey.isValidSignature(raw, for: zip)
    }

    /// `v1.6.0` → `1.6.0`.
    static func version(ofTag tag: String) -> String {
        tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
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

/// A newer release the app can install itself: its zip and the zip's signature.
struct AppRelease: Equatable, Sendable {
    var tag: String
    var zip: URL
    var signature: URL
}

@MainActor
final class AppUpdateChecker {
    static let lastCheckKey = "pg.update.lastCheck"
    static let remoteTagKey = "pg.update.remoteTag"
    static let remoteZipKey = "pg.update.remoteZip"
    static let remoteSignatureKey = "pg.update.remoteSig"

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

    /// Asks GitHub now, even if today's check already ran. False when GitHub didn't answer.
    func checkNow() async -> Bool {
        await fetch()
    }

    @discardableResult
    private func fetch() async -> Bool {
        var request = URLRequest(url: AppUpdate.latestAPIURL)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let tag = AppUpdate.tag(fromAPIJSON: data)
        else {
            publishCached()
            return false
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        defaults.set(tag, forKey: Self.remoteTagKey)
        defaults.set(AppUpdate.zipURL(fromAPIJSON: data)?.absoluteString, forKey: Self.remoteZipKey)
        defaults.set(AppUpdate.signatureURL(fromAPIJSON: data)?.absoluteString, forKey: Self.remoteSignatureKey)
        publish(tag)
        return true
    }

    /// The newer release saved by the last check, when it has a zip and a signature to install from.
    var release: AppRelease? {
        guard let tag = defaults.string(forKey: Self.remoteTagKey),
              AppUpdate.isNewer(tag, than: localVersion),
              let zip = defaults.string(forKey: Self.remoteZipKey).flatMap(URL.init(string:)),
              let signature = defaults.string(forKey: Self.remoteSignatureKey).flatMap(URL.init(string:))
        else { return nil }
        return AppRelease(tag: tag, zip: zip, signature: signature)
    }

    /// Downloads the release's zip and signature. Nil when either doesn't arrive whole.
    func download(_ release: AppRelease) async -> (zip: Data, signature: Data)? {
        guard let signature = await get(release.signature, limit: 4096),
              let zip = await get(release.zip, limit: AppUpdate.maxDownload)
        else { return nil }
        return (zip, signature)
    }

    // ponytail: reads the whole body before checking `limit`, which is fine for github.com over HTTPS.
    // If downloads ever come from elsewhere, stream with `session.bytes(for:)` and stop at the limit.
    private func get(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= limit
        else { return nil }
        return data
    }

    /// The newest release's zip, saved with its tag, else the release page.
    var downloadURL: URL {
        defaults.string(forKey: Self.remoteZipKey).flatMap(URL.init(string:)) ?? AppUpdate.latestReleaseURL
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
