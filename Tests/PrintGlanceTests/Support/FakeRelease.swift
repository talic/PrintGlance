import CryptoKit
import Foundation
@testable import PrintGlance

/// A pretend PrintGlance release: an app bundle, zipped like `make zip`, signed like `make sign-release`.
enum FakeRelease {
    static let bundleID = "local.PrintGlance"

    /// The least of an app that `AppInstaller.isApp` accepts: an Info.plist and an executable.
    @discardableResult
    static func app(at url: URL, version: String, bundleID: String = bundleID, executable: Bool = true) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "PrintGlance",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if executable {
            let exe = contents.appendingPathComponent("MacOS/PrintGlance")
            try Data("#!/bin/sh\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        return url
    }

    /// The version an installed app's Info.plist says.
    static func version(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// `ditto -c -k --keepParent`, as `make zip` packs a release. Several items go in side by side.
    static func zip(_ items: URL..., in dir: URL) throws -> Data {
        let parent = dir.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for item in items {
            try FileManager.default.copyItem(at: item, to: parent.appendingPathComponent(item.lastPathComponent))
        }
        let out = dir.appendingPathComponent("\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // One item zips as itself, like --keepParent on the app; several sit at the top level.
        p.arguments = items.count == 1
            ? ["-c", "-k", "--keepParent", parent.appendingPathComponent(items[0].lastPathComponent).path, out.path]
            : ["-c", "-k", parent.path, out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: out)
    }

    /// The `PrintGlance.zip.sig` text: the base64 signature and a newline.
    static func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) -> Data {
        Data(((try? key.signature(for: data))?.base64EncodedString() ?? "" ).utf8) + Data("\n".utf8)
    }

    static func zipURL(_ tag: String) -> URL {
        URL(string: "https://github.com/talic/PrintGlance/releases/download/\(tag)/PrintGlance.zip")!
    }

    static func signatureURL(_ tag: String) -> URL {
        URL(string: "https://github.com/talic/PrintGlance/releases/download/\(tag)/PrintGlance.zip.sig")!
    }

    /// GitHub's latest-release answer with the zip and, unless left out, its signature.
    static func json(_ tag: String, signature: Bool = true) -> String {
        var assets = [#"{"name":"PrintGlance.zip","browser_download_url":"\#(zipURL(tag))"}"#]
        if signature {
            assets.append(#"{"name":"PrintGlance.zip.sig","browser_download_url":"\#(signatureURL(tag))"}"#)
        }
        return #"{"tag_name":"\#(tag)","assets":[\#(assets.joined(separator: ","))]}"#
    }
}
