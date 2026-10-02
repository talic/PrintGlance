import Foundation
import Network
import Security
import XCTest
@testable import PrintGlance

/// A printer's MQTT broker on 127.0.0.1, over TLS with a throwaway self-signed certificate, so
/// `MQTT311Client` runs its real socket, TLS, and framing code. Plays one client at a time.
final class FakeBroker: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.broker")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var inbox = Data()
    private var received: [[UInt8]] = []

    /// CONNACK return code sent for CONNECT; nil sends nothing (a printer that never answers).
    init(connack: UInt8? = 0) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try Self.identity())
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, connack: connack) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw XCTSkip("Loopback listener did not start")
        }
        self.port = port
    }

    deinit {
        listener.cancel()
        connection?.cancel()
    }

    /// Packets the client sent, whole, oldest first.
    var packets: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func packets(ofType type: UInt8) -> [[UInt8]] {
        packets.filter { $0.first.map { $0 >> 4 } == type }
    }

    /// Bytes to the client as one write. Each call is its own TLS record.
    func send(_ bytes: [UInt8]) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.connection?.send(content: Data(bytes), completion: .contentProcessed { _ in done.signal() })
        }
        _ = done.wait(timeout: .now() + 5)
    }

    /// The printer hangs up.
    func close() {
        queue.sync {
            connection?.cancel()
            connection = nil
        }
    }

    /// Waits off the main thread's run loop so main-queue callbacks keep flowing.
    func waitFor(_ type: UInt8, count: Int = 1, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date() + timeout
        while packets(ofType: type).count < count {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date() + 0.01)
        }
        return true
    }

    private func accept(_ conn: NWConnection, connack: UInt8?) {
        connection?.cancel()
        connection = conn
        inbox = Data()
        conn.start(queue: queue)
        receive(conn, connack: connack)
    }

    private func receive(_ conn: NWConnection, connack: UInt8?) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil else { return }
            if let data { self.inbox.append(data) }
            while let packet = self.takePacket() {
                self.lock.lock()
                self.received.append(packet)
                self.lock.unlock()
                if packet.first == 0x10, let code = connack {
                    conn.send(content: Data([0x20, 0x02, 0x00, code]), completion: .idempotent)
                }
            }
            if !done { self.receive(conn, connack: connack) }
        }
    }

    private func takePacket() -> [UInt8]? {
        let bytes = [UInt8](inbox)
        guard bytes.count >= 2, let (len, size) = MQTT311Client.decodeRemainingLength(bytes, start: 1) else { return nil }
        let total = 1 + size + len
        guard bytes.count >= total else { return nil }
        inbox.removeFirst(total)
        return Array(bytes[0..<total])
    }

    // MARK: - Packets a printer sends

    static func publish(topic: String, payload: [UInt8], qos: UInt8 = 0, packetID: UInt16 = 7) -> [UInt8] {
        var body = [UInt8](MQTT311Client.mqttString(topic))
        if qos > 0 { body += [UInt8(packetID >> 8), UInt8(packetID & 0xFF)] }
        body += payload
        return [0x30 | (qos << 1)] + [UInt8](MQTT311Client.encodeRemainingLength(body.count)) + body
    }

    static func publish(_ json: String) -> [UInt8] {
        publish(topic: "device/20P9AJ5B0700123/report", payload: Array(json.utf8))
    }

    // MARK: - Certificate

    nonisolated(unsafe) private static var cached: sec_identity_t?
    private static let cacheLock = NSLock()

    /// A self-signed localhost identity made by `/usr/bin/openssl` and kept in memory only.
    /// Nothing is written to a keychain, and no key is committed to the repo.
    private static func identity() throws -> sec_identity_t {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        guard #available(macOS 15, *) else { throw XCTSkip("In-memory PKCS#12 import needs macOS 15") }
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else { throw XCTSkip("No /usr/bin/openssl") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "1", "-subj", "/CN=localhost"],
            ["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "id.p12", "-passout", "pass:printglance"],
        ] {
            let p = Process()
            p.executableURL = openssl
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw XCTSkip("openssl \(args[0]) failed") }
        }
        let p12 = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
        var items: CFArray?
        let options = [kSecImportExportPassphrase: "printglance", kSecImportToMemoryOnly: true] as CFDictionary
        guard SecPKCS12Import(p12 as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              let identity = sec_identity_create(value as! SecIdentity)
        else { throw XCTSkip("Could not import the test identity") }
        cached = identity
        return identity
    }
}

/// What an `MQTT311Client` reported, from the main queue.
final class ClientEvents: @unchecked Sendable {
    private(set) var connects = 0
    private(set) var disconnects: [String?] = []
    private(set) var messages: [(topic: String, payload: Data)] = []

    func attach(_ client: MQTT311Client) {
        client.onConnect = { [self] in connects += 1 }
        client.onDisconnect = { [self] in disconnects.append($0) }
        client.onMessage = { [self] in messages.append(($0, $1)) }
    }

    /// Spins the main run loop, where the client delivers callbacks.
    func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date() + timeout
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date() + 0.01)
        }
        return true
    }

    /// Lets in-flight callbacks land, for asserting that nothing more arrives.
    func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date() + seconds)
    }
}
