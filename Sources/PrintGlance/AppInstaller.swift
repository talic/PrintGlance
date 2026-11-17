import Foundation

/// Puts a downloaded release in place of this app. It checks the zip's signature before unpacking
/// anything, checks the unpacked app is PrintGlance and newer, then swaps the bundle in one rename.
/// The download never gets the quarantine flag (only browsers and opted-in apps set it), so the
/// signature is what stands in for Gatekeeper's first-open check.
struct AppInstaller: Sendable {
    enum Failure: Error, Equatable {
        /// Not run from an `.app`, translocated by Gatekeeper, or its folder isn't writable.
        case cantReplace
        case badSignature
        case unzip
        /// The zip doesn't hold one PrintGlance app with the release's version.
        case notTheRelease
        case notNewer
        case swap
    }

    var appURL: URL
    var bundleID: String
    var localVersion: String
    var key: String

    static let running = AppInstaller(
        appURL: Bundle.main.bundleURL,
        bundleID: Bundle.main.bundleIdentifier ?? "",
        localVersion: AppUpdate.bundledVersion,
        key: AppUpdate.signingKey
    )

    /// False when PrintGlance can't replace itself. Clicking **Update available** then opens the
    /// download in the browser, as before 1.6.
    var canInstall: Bool {
        let fm = FileManager.default
        guard appURL.pathExtension == "app", !appURL.path.contains("/AppTranslocation/") else { return false }
        return fm.isWritableFile(atPath: appURL.path)
            && fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    /// Off the main actor: unzipping takes a moment.
    func install(zip: Data, signature: Data, tag: String) async throws {
        try await Task.detached { [self] in
            try self.installNow(zip: zip, signature: signature, tag: tag)
        }.value
    }

    private func installNow(zip: Data, signature: Data, tag: String) throws {
        guard canInstall else { throw Failure.cantReplace }
        guard AppUpdate.isSigned(zip, signature: signature, key: key) else { throw Failure.badSignature }
        let version = AppUpdate.version(ofTag: tag)
        guard AppUpdate.isNewer(version, than: localVersion) else { throw Failure.notNewer }

        let fm = FileManager.default
        // On the app's own volume, so the swap is a rename.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? fm.removeItem(at: staging) }
        let zipFile = staging.appendingPathComponent(AppUpdate.zipName)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try zip.write(to: zipFile)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path]) else { throw Failure.unzip }

        let items = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard items.count == 1, let newApp = items.first, newApp.pathExtension == "app",
              Self.isApp(newApp, bundleID: bundleID, version: version)
        else { throw Failure.notTheRelease }

        do {
            _ = try fm.replaceItemAt(appURL, withItemAt: newApp, backupItemName: nil, options: .usingNewMetadataOnly)
        } catch {
            throw Failure.swap
        }
    }

    /// The bundle's Info.plist names this app and the release's version, and its executable is there.
    static func isApp(_ url: URL, bundleID: String, version: String) -> Bool {
        let contents = url.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version,
              let executable = info["CFBundleExecutable"] as? String, !executable.contains("/")
        else { return false }
        return FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/\(executable)").path)
    }

    /// Opens the app again once this copy has quit (`LSMultipleInstancesProhibited` refuses a second
    /// copy before then). False when the helper didn't start; the new version then waits for the next launch.
    static func reopenAfterQuit(_ appURL: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            return true
        } catch {
            return false
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
