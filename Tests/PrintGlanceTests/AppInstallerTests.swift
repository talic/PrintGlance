import CryptoKit
import Foundation
import XCTest
@testable import PrintGlance

/// Installing a release over the app: the real unzip and swap, in a scratch folder standing in for Applications.
final class AppInstallerTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = scratchDirectory()
    }

    /// PrintGlance 1.5.0 in a scratch Applications folder, trusting `key`.
    private func installed(_ name: String = "PrintGlance.app", version: String = "1.5.0") throws -> AppInstaller {
        let app = try FakeRelease.app(at: dir.appendingPathComponent("Applications/\(name)"), version: version)
        return AppInstaller(
            appURL: app,
            bundleID: FakeRelease.bundleID,
            localVersion: version,
            key: key.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    private func release(_ version: String, bundleID: String = FakeRelease.bundleID, executable: Bool = true) throws -> Data {
        let work = dir.appendingPathComponent("build-\(UUID().uuidString)")
        return try FakeRelease.zip(
            FakeRelease.app(at: work.appendingPathComponent("PrintGlance.app"), version: version, bundleID: bundleID, executable: executable),
            in: work
        )
    }

    private func assertRefused(
        _ installer: AppInstaller, _ zip: Data, signature: Data? = nil, tag: String = "v1.6.0",
        _ expected: AppInstaller.Failure, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await installer.install(zip: zip, signature: signature ?? FakeRelease.sign(zip, with: key), tag: tag)
            XCTFail("installed", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppInstaller.Failure, expected, file: file, line: line)
        }
        XCTAssertEqual(FakeRelease.version(at: installer.appURL), installer.localVersion, "the app is untouched", file: file, line: line)
    }

    func testSignedNewerReleaseReplacesTheApp() async throws {
        let installer = try installed()
        XCTAssertTrue(installer.canInstall)
        let zip = try release("1.6.0")
        try await installer.install(zip: zip, signature: FakeRelease.sign(zip, with: key), tag: "v1.6.0")
        XCTAssertEqual(FakeRelease.version(at: installer.appURL), "1.6.0")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.appURL.appendingPathComponent("Contents/MacOS/PrintGlance").path))
        let left = try FileManager.default.contentsOfDirectory(atPath: installer.appURL.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["PrintGlance.app"], "no backup or staging left next to it")
    }

    func testAppTheUserRenamedKeepsItsName() async throws {
        let installer = try installed("PrintGlance 2.app")
        let zip = try release("1.6.0")
        try await installer.install(zip: zip, signature: FakeRelease.sign(zip, with: key), tag: "v1.6.0")
        XCTAssertEqual(FakeRelease.version(at: installer.appURL), "1.6.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Applications/PrintGlance.app").path))
    }

    func testAZipWithoutTheRightSignatureIsNeverUnpacked() async throws {
        let installer = try installed()
        let zip = try release("1.6.0")
        var tampered = zip
        tampered[tampered.count / 2] ^= 0xFF
        await assertRefused(installer, tampered, signature: FakeRelease.sign(zip, with: key), .badSignature)
        await assertRefused(installer, zip, signature: FakeRelease.sign(zip, with: Curve25519.Signing.PrivateKey()), .badSignature)
        await assertRefused(installer, zip, signature: FakeRelease.sign(try release("1.6.1"), with: key), .badSignature)
        for garbage in ["", "\n", "not base64!", String(repeating: "A", count: 88)] {
            await assertRefused(installer, zip, signature: Data(garbage.utf8), .badSignature)
        }
        var noKey = installer
        noKey.key = ""
        await assertRefused(noKey, zip, .badSignature)
    }

    func testTheZipMustHoldThisAppAtTheTaggedVersion() async throws {
        let installer = try installed()
        await assertRefused(installer, try release("1.6.1"), tag: "v1.6.0", .notTheRelease)
        await assertRefused(installer, try release("1.6.0", bundleID: "com.example.Other"), .notTheRelease)
        await assertRefused(installer, try release("1.6.0", executable: false), .notTheRelease)
        let work = dir.appendingPathComponent("two")
        let two = try FakeRelease.zip(
            FakeRelease.app(at: work.appendingPathComponent("PrintGlance.app"), version: "1.6.0"),
            FakeRelease.app(at: work.appendingPathComponent("Other.app"), version: "1.6.0"),
            in: work
        )
        await assertRefused(installer, two, .notTheRelease)
    }

    func testAnOlderSignedReleaseIsNotInstalled() async throws {
        let installer = try installed()
        await assertRefused(installer, try release("1.5.0"), tag: "v1.5.0", .notNewer)
        await assertRefused(installer, try release("1.4.0"), tag: "v1.4.0", .notNewer)
    }

    func testASignedFileThatIsNotAZipFailsToUnpack() async throws {
        await assertRefused(try installed(), Data("not a zip".utf8), .unzip)
    }

    func testNoInstallWhereItCantReplaceItself() async throws {
        var installer = try installed()
        let zip = try release("1.6.0")

        let folder = installer.appURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertFalse(installer.canInstall, "a folder this account can't change")
        await assertRefused(installer, zip, .cantReplace)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertTrue(installer.canInstall)

        for path in [
            "/private/var/folders/xy/AppTranslocation/1234/d/PrintGlance.app",
            dir.appendingPathComponent(".build/debug/PrintGlance").path,
            dir.appendingPathComponent("Applications/Missing.app").path,
        ] {
            installer.appURL = URL(fileURLWithPath: path)
            XCTAssertFalse(installer.canInstall, path)
        }
    }
}
