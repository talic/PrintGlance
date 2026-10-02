import Foundation
import XCTest
@testable import PrintGlance

/// `MQTT311Client` against a real TLS socket on loopback (`FakeBroker`): the bytes it sends, and how it
/// reads what a printer, or something pretending to be one, sends back.
final class MQTTWireTests: XCTestCase {
    private let serial = "20P9AJ5B0700123"
    private var client: MQTT311Client!
    private var events: ClientEvents!

    override func setUp() {
        super.setUp()
        client = MQTT311Client()
        events = ClientEvents()
        events.attach(client)
    }

    override func tearDown() {
        client.disconnect()
        client = nil
        events = nil
        super.tearDown()
    }

    private func dial(_ broker: FakeBroker, password: String = "a1b2c3d4") {
        client.connect(host: "127.0.0.1", port: broker.port, clientID: "pg-app-700123-beef", username: "bblp", password: password)
    }

    private func connected() throws -> FakeBroker {
        let broker = try FakeBroker()
        dial(broker)
        XCTAssertTrue(events.wait { self.events.connects == 1 }, "no CONNACK")
        return broker
    }

    // MARK: - What the app sends

    func testConnectCarriesTheAccessCodeAsThePassword() throws {
        let broker = try FakeBroker()
        dial(broker)
        XCTAssertTrue(broker.waitFor(1))
        let connect = try XCTUnwrap(broker.packets(ofType: 1).first)
        XCTAssertEqual(connect, [UInt8](MQTT311Client.connectPacket(clientID: "pg-app-700123-beef", username: "bblp", password: "a1b2c3d4", keepAlive: 30)))
        // Variable header: "MQTT", level 4, flags username + password + clean session, keep-alive 30 s.
        XCTAssertEqual(Array(connect[2..<12]), [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0xC2, 0x00, 0x1E])
        XCTAssertTrue(events.wait { self.events.connects == 1 })
    }

    func testSubscribeAndPushallAreTheOnlyRequests() throws {
        let broker = try connected()
        client.subscribe("device/\(serial)/report")
        client.publish(topic: "device/\(serial)/request", payload: Data(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8))
        XCTAssertTrue(broker.waitFor(8))
        XCTAssertTrue(broker.waitFor(3))
        let subscribe = try XCTUnwrap(broker.packets(ofType: 8).first)
        XCTAssertEqual(subscribe[0], 0x82, "SUBSCRIBE has fixed flags 0010")
        XCTAssertEqual(Array(subscribe.suffix(1)), [0x00], "QoS 0")
        XCTAssertEqual(String(decoding: subscribe[6..<(subscribe.count - 1)], as: UTF8.self), "device/\(serial)/report")
        let publish = try XCTUnwrap(broker.packets(ofType: 3).first)
        XCTAssertEqual(publish[0], 0x30, "QoS 0, not retained")
        XCTAssertEqual(publish, FakeBroker.publish(topic: "device/\(serial)/request", payload: Array(#"{"pushing":{"command":"pushall","sequence_id":"0"}}"#.utf8)))
    }

    // MARK: - Handshake outcomes

    func testRejectedAccessCodeReportsTheConnackCode() throws {
        let broker = try FakeBroker(connack: 5)
        dial(broker, password: "wrong")
        XCTAssertTrue(events.wait { !self.events.disconnects.isEmpty })
        XCTAssertEqual(events.disconnects, ["MQTT CONNACK 5"])
        XCTAssertEqual(events.connects, 0)
        XCTAssertTrue(GlanceCopy.codeRejected(events.disconnects.first ?? nil), "the card offers Update Access Code…")
    }

    func testRefusedPortReportsTheStableToken() throws {
        var broker: FakeBroker? = try FakeBroker()
        let port = try XCTUnwrap(broker?.port)
        broker = nil // closes the listener; nothing answers on that port now
        events.settle(0.1)
        client.connect(host: "127.0.0.1", port: port, clientID: "pg-app-test", username: "bblp", password: "x")
        XCTAssertTrue(events.wait { !self.events.disconnects.isEmpty })
        XCTAssertEqual(events.disconnects, ["ECONNREFUSED"])
    }

    func testPrinterHangingUpIsReported() throws {
        let broker = try connected()
        broker.close()
        XCTAssertTrue(events.wait { self.events.disconnects.count == 1 })
        events.settle()
        XCTAssertEqual(events.disconnects.count, 1, "one drop, one callback")
    }

    func testAcceptsAnySelfSignedCertificate() throws {
        // ponytail in MQTT311Client: the printer's certificate is signed by Bambu's own CA, so the client
        // trusts anything. This pins that behavior so a future pinning change is deliberate.
        _ = try connected()
    }

    // MARK: - Reading reports

    func testReportArrives() throws {
        let broker = try connected()
        broker.send(FakeBroker.publish(#"{"print":{"gcode_state":"RUNNING"}}"#))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first?.topic, "device/\(serial)/report")
        XCTAssertEqual(events.messages.first.map { String(decoding: $0.payload, as: UTF8.self) }, #"{"print":{"gcode_state":"RUNNING"}}"#)
    }

    func testReportSplitAcrossManyReadsIsReassembled() throws {
        let broker = try connected()
        let packet = FakeBroker.publish(#"{"print":{"mc_percent":52}}"#)
        for byte in packet { broker.send([byte]) }
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first.map { String(decoding: $0.payload, as: UTF8.self) }, #"{"print":{"mc_percent":52}}"#)
    }

    func testTwoReportsInOneReadBothArriveInOrder() throws {
        let broker = try connected()
        broker.send(FakeBroker.publish(#"{"n":1}"#) + FakeBroker.publish(#"{"n":2}"#))
        XCTAssertTrue(events.wait { self.events.messages.count == 2 })
        XCTAssertEqual(events.messages.map { String(decoding: $0.payload, as: UTF8.self) }, [#"{"n":1}"#, #"{"n":2}"#])
    }

    func testFullReportLargerThanOneReadArrivesWhole() throws {
        let broker = try connected()
        // A pushall from an X1 with four AMS units runs to tens of KB; reads are capped at 64 KB.
        let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 150_000)
        broker.send(FakeBroker.publish(topic: "device/\(serial)/report", payload: payload))
        XCTAssertTrue(events.wait(timeout: 10) { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first?.payload.count, 150_000)
    }

    func testQoS1ReportSkipsThePacketID() throws {
        let broker = try connected()
        broker.send(FakeBroker.publish(topic: "t", payload: Array("{}".utf8), qos: 1))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first.map { String(decoding: $0.payload, as: UTF8.self) }, "{}")
    }

    func testOtherPacketTypesAreIgnored() throws {
        let broker = try connected()
        broker.send([0xD0, 0x00]) // PINGRESP
        broker.send([0x90, 0x03, 0x00, 0x01, 0x00]) // SUBACK
        broker.send([0xF0, 0x00]) // reserved type 15
        broker.send(FakeBroker.publish(#"{"after":true}"#))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertTrue(events.disconnects.isEmpty)
    }

    // MARK: - Hostile bytes

    func testGarbageLengthDropsTheConnection() throws {
        let broker = try connected()
        broker.send([0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        XCTAssertTrue(events.wait { !self.events.disconnects.isEmpty })
        XCTAssertEqual(events.disconnects, ["malformed packet"])
        XCTAssertTrue(events.messages.isEmpty)
    }

    func testOversizedPacketDropsTheConnectionBeforeBuffering() throws {
        let broker = try connected()
        // Remaining length 6 MB; the body never comes, and the client mustn't wait to hold it.
        broker.send([0x30, 0x80, 0x80, 0x80, 0x03])
        XCTAssertTrue(events.wait { !self.events.disconnects.isEmpty })
        XCTAssertEqual(events.disconnects, ["packet too large"])
        XCTAssertGreaterThan(6 << 20, MQTT311Client.maxPacketSize)
    }

    func testTopicLongerThanItsPacketIsSkipped() throws {
        let broker = try connected()
        // Remaining length 4, but the topic claims 0x7FFF bytes.
        broker.send([0x30, 0x04, 0x7F, 0xFF, 0x41, 0x42])
        broker.send(FakeBroker.publish(#"{"ok":1}"#))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first.map { String(decoding: $0.payload, as: UTF8.self) }, #"{"ok":1}"#)
        XCTAssertTrue(events.disconnects.isEmpty)
    }

    func testTruncatedPublishIsSkipped() throws {
        let broker = try connected()
        broker.send([0x30, 0x01, 0x00]) // no room for a topic length
        broker.send(FakeBroker.publish(#"{"ok":2}"#))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertTrue(events.disconnects.isEmpty)
    }

    func testTopicThatIsNotUTF8StillDeliversThePayload() throws {
        let broker = try connected()
        broker.send(FakeBroker.publish(topic: "", payload: Array("{}".utf8)).replacingTopic(with: [0xFF, 0xFE]))
        XCTAssertTrue(events.wait { self.events.messages.count == 1 })
        XCTAssertEqual(events.messages.first?.topic, "")
    }

    // MARK: - Generations

    func testDisconnectSilencesTheOldSocket() throws {
        let broker = try connected()
        client.disconnect()
        broker.send(FakeBroker.publish(#"{"late":true}"#))
        broker.close()
        events.settle()
        XCTAssertTrue(events.messages.isEmpty)
        XCTAssertTrue(events.disconnects.isEmpty, "a disconnect we asked for is not a drop")
    }

    func testReconnectIgnoresTheSocketItReplaced() throws {
        let first = try connected()
        let second = try FakeBroker()
        dial(second)
        XCTAssertTrue(second.waitFor(1))
        first.close()
        XCTAssertTrue(events.wait { self.events.connects == 2 })
        events.settle()
        XCTAssertTrue(events.disconnects.isEmpty, "the old socket closing must not fail the new attempt")
    }

    // MARK: - Packet builders

    func testStringsAreLengthPrefixedInBytesNotCharacters() {
        XCTAssertEqual([UInt8](MQTT311Client.mqttString("é")), [0x00, 0x02, 0xC3, 0xA9])
        XCTAssertEqual([UInt8](MQTT311Client.mqttString("")), [0x00, 0x00])
    }

    func testRemainingLengthUsesMoreBytesPast127() {
        XCTAssertEqual([UInt8](MQTT311Client.encodeRemainingLength(127)), [0x7F])
        XCTAssertEqual([UInt8](MQTT311Client.encodeRemainingLength(128)), [0x80, 0x01])
        XCTAssertEqual([UInt8](MQTT311Client.encodeRemainingLength(16_384)), [0x80, 0x80, 0x01])
        let big = MQTT311Client.publishPacket(topic: "t", payload: Data(count: 300))
        XCTAssertEqual(Array(big.prefix(3)), [0x30, 0xAF, 0x02], "3 + 300 = 303 bytes")
    }

    func testSubscribeUsesTheGivenPacketID() {
        XCTAssertEqual(
            [UInt8](MQTT311Client.subscribePacket(id: 0x1234, topic: "a/b")),
            [0x82, 0x08, 0x12, 0x34, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x00]
        )
    }
}

private extension Array where Element == UInt8 {
    /// Swaps an empty topic's two-byte length for `topic`'s bytes and length, keeping the payload.
    func replacingTopic(with topic: [UInt8]) -> [UInt8] {
        let payload = Array(self[4...])
        let body = [UInt8(topic.count >> 8), UInt8(topic.count & 0xFF)] + topic + payload
        return [self[0]] + [UInt8](MQTT311Client.encodeRemainingLength(body.count)) + body
    }
}
