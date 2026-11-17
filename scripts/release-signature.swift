// Signs PrintGlance release zips for the app's updater. The private key lives in this Mac's login
// Keychain and is never printed; the app has the public key (`AppUpdate.signingKey`).
//
//   swift scripts/release-signature.swift new        make the key once, print its public key
//   swift scripts/release-signature.swift public     print the public key
//   swift scripts/release-signature.swift sign <zip> <public key the app trusts>
//                                                    print the zip's signature (base64)
//
// `make update-key` and `make sign-release TAG=vX.Y.Z` run it.
import CryptoKit
import Foundation
import Security

let service = "PrintGlance release signing key"
let account = "PrintGlance"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = out as? Data else { fail("Can't read the signing key from the Keychain (\(status)).") }
    // Stored as base64 text, so `security find-generic-password -w` backs it up as one line.
    guard let text = String(data: data, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("The Keychain item \"\(service)\" isn't a signing key.") }
    return key
}

func publicText(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "new":
    if let key = storedKey() {
        fail("This Mac already has a signing key. Its public key is \(publicText(key))")
    }
    let key = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: service,
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Can't save the signing key to the Keychain (\(status)).") }
    print(publicText(key))

case "public":
    guard let key = storedKey() else { fail("No signing key in this Mac's login Keychain. Run make update-key.") }
    print(publicText(key))

case "sign":
    guard args.count == 3 else { fail("Usage: release-signature.swift sign <zip> <public key>") }
    guard let key = storedKey() else { fail("No signing key in this Mac's login Keychain.") }
    guard publicText(key) == args[2] else {
        fail("This Mac's signing key isn't the one in AppUpdate.signingKey, so the app would refuse the update.")
    }
    guard let zip = FileManager.default.contents(atPath: args[1]), !zip.isEmpty else { fail("Can't read \(args[1]).") }
    let signature = try key.signature(for: zip)
    guard key.publicKey.isValidSignature(signature, for: zip) else { fail("The signature didn't verify.") }
    print(signature.base64EncodedString())

default:
    fail("Usage: release-signature.swift new | public | sign <zip> <public key>")
}
