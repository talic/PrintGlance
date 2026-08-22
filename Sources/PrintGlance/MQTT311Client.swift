import Foundation
import Network

/// Minimal MQTT 3.1.1 client (connect, subscribe QoS 0, publish QoS 0, ping).
final class MQTT311Client: @unchecked Sendable {
    var onConnect: (() -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onMessage: ((String, Data) -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "local.PrintGlance.mqtt")
    private let keepAlive: UInt16 = 30
    private var packetID: UInt16 = 1
    /// Bumped on each `connect` / `disconnect` so a cancelled socket cannot
    /// fail the attempt that replaced it.
    private var generation: UInt64 = 0

    /// 1s, 2s, 4s, 8s, 16s, then 30s. `attempt` is 1 after the first drop.
    static func reconnectDelaySeconds(attempt: Int) -> TimeInterval {
        let n = max(attempt, 1)
        let shift = min(n - 1, 5)
        return min(30, TimeInterval(1 << shift))
    }

    static func reconnectDelayNanoseconds(attempt: Int) -> UInt64 {
        UInt64(reconnectDelaySeconds(attempt: attempt) * 1_000_000_000)
    }

    func connect(host: String, port: UInt16, clientID: String, username: String, password: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            let gen = self.generation
            self.connectOnQueue(
                host: host, port: port, clientID: clientID, username: username, password: password,
                generation: gen
            )
        }
    }

    private func connectOnQueue(
        host: String,
        port: UInt16,
        clientID: String,
        username: String,
        password: String,
        generation: UInt64
    ) {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global()
        )
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8883,
            using: params
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.generation else { return }
            switch state {
            case .ready:
                self.receiveLoop(generation: generation)
                self.send(
                    Self.connectPacket(
                        clientID: clientID, username: username, password: password, keepAlive: self.keepAlive
                    ),
                    generation: generation
                )
            case let .failed(err):
                self.fail("\(err)", generation: generation)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func subscribe(_ topic: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(Self.subscribePacket(id: self.nextID(), topic: topic), generation: self.generation)
        }
    }

    func publish(topic: String, payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(Self.publishPacket(topic: topic, payload: payload), generation: self.generation)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.connection?.cancel()
            self.connection = nil
            self.buffer.removeAll()
        }
    }

    private func fail(_ reason: String?, generation: UInt64) {
        guard generation == self.generation else { return }
        self.generation &+= 1
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?(reason)
        }
    }

    private func nextID() -> UInt16 {
        packetID = packetID == UInt16.max ? 1 : packetID + 1
        return packetID
    }

    private func send(_ data: Data, generation: UInt64) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] err in
            if let err { self?.fail("\(err)", generation: generation) }
        })
    }

    private func receiveLoop(generation: UInt64) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, err in
            guard let self, generation == self.generation else { return }
            if let err {
                self.fail("\(err)", generation: generation)
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain(generation: generation)
            }
            if isComplete {
                self.fail("closed", generation: generation)
                return
            }
            self.receiveLoop(generation: generation)
        }
    }

    private func drain(generation: UInt64) {
        while true {
            let bytes = [UInt8](buffer)
            guard bytes.count >= 2 else { return }
            guard let (len, size) = Self.decodeRemainingLength(bytes, start: 1) else { return }
            let total = 1 + size + len
            guard bytes.count >= total else { return }
            let packet = Array(bytes.prefix(total))
            buffer = Data(bytes.dropFirst(total))
            handle(packet, generation: generation)
        }
    }

    private func handle(_ packet: [UInt8], generation: UInt64) {
        guard let first = packet.first else { return }
        let type = first >> 4
        switch type {
        case 2: // CONNACK
            let code = packet.count >= 4 ? packet[3] : 1
            if code == 0 {
                startPing(generation: generation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.onConnect?()
                }
            } else {
                fail("MQTT CONNACK \(code)", generation: generation)
            }
        case 3: // PUBLISH
            parsePublish(packet, generation: generation)
        case 13: // PINGRESP
            break
        default:
            break
        }
    }

    private func parsePublish(_ packet: [UInt8], generation: UInt64) {
        guard let first = packet.first,
              let (len, size) = Self.decodeRemainingLength(packet, start: 1) else { return }
        let qos = (first >> 1) & 0x03
        var i = 1 + size
        guard i + 2 <= packet.count else { return }
        let tlen = Int(packet[i]) << 8 | Int(packet[i + 1])
        i += 2
        guard i + tlen <= packet.count else { return }
        let topic = String(bytes: packet[i ..< (i + tlen)], encoding: .utf8) ?? ""
        i += tlen
        if qos > 0 { i += 2 }
        let payload = i <= packet.count ? Data(packet[i...]) : Data()
        _ = len
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else { return }
            self.onMessage?(topic, payload)
        }
    }

    private func startPing(generation: UInt64) {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self, generation == self.generation else { return }
            self.send(Data([0xC0, 0x00]), generation: generation)
        }
        t.resume()
        pingTimer = t
    }

    static func decodeRemainingLength(_ data: [UInt8], start: Int) -> (Int, Int)? {
        var multiplier = 1
        var value = 0
        var size = 0
        var i = start
        while i < data.count {
            let encoded = Int(data[i])
            i += 1
            size += 1
            value += (encoded & 127) * multiplier
            if encoded & 128 == 0 { return (value, size) }
            multiplier *= 128
            if size >= 4 { return nil }
        }
        return nil
    }

    static func encodeRemainingLength(_ n: Int) -> Data {
        var x = n
        var out = Data()
        repeat {
            var enc = UInt8(x % 128)
            x /= 128
            if x > 0 { enc |= 0x80 }
            out.append(enc)
        } while x > 0
        return out
    }

    static func mqttString(_ s: String) -> Data {
        let utf = Data(s.utf8)
        var d = Data([UInt8(utf.count >> 8), UInt8(utf.count & 0xFF)])
        d.append(utf)
        return d
    }

    static func connectPacket(clientID: String, username: String, password: String, keepAlive: UInt16) -> Data {
        var vh = Data()
        vh.append(mqttString("MQTT"))
        vh.append(contentsOf: [UInt8(4), UInt8(0xC2)])
        vh.append(UInt8(keepAlive >> 8))
        vh.append(UInt8(keepAlive & 0xFF))
        vh.append(mqttString(clientID))
        vh.append(mqttString(username))
        vh.append(mqttString(password))
        var pkt = Data([0x10])
        pkt.append(encodeRemainingLength(vh.count))
        pkt.append(vh)
        return pkt
    }

    static func subscribePacket(id: UInt16, topic: String) -> Data {
        var vh = Data([UInt8(id >> 8), UInt8(id & 0xFF)])
        vh.append(mqttString(topic))
        vh.append(UInt8(0))
        var pkt = Data([0x82])
        pkt.append(encodeRemainingLength(vh.count))
        pkt.append(vh)
        return pkt
    }

    static func publishPacket(topic: String, payload: Data) -> Data {
        var vh = mqttString(topic)
        vh.append(payload)
        var pkt = Data([0x30])
        pkt.append(encodeRemainingLength(vh.count))
        pkt.append(vh)
        return pkt
    }
}
