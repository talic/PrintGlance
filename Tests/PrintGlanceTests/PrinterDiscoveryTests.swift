import XCTest
@testable import PrintGlance

final class PrinterDiscoveryTests: XCTestCase {
    func testParseSSDPReplyIntoIPSerialName() throws {
        let notify = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1990\r
        SERVER: UPnP/1.0\r
        LOCATION: 192.0.2.10\r
        NT: urn:bambulab-com:device:3dprinter:1\r
        NTS: ssdp:alive\r
        USN: 01P00A123456789\r
        CACHE-CONTROL: max-age=1800\r
        DevModel.bambu.com: C12\r
        DevName.bambu.com: Studio P1S\r
        DevConnect.bambu.com: lan\r
        AccessCode: must-not-fill\r
        """
        let hit = try XCTUnwrap(PrinterDiscovery.parse(notify))
        XCTAssertEqual(hit.ip, "192.0.2.10")
        XCTAssertEqual(hit.serial, "01P00A123456789")
        XCTAssertEqual(hit.name, "Studio P1S")
        XCTAssertEqual(hit.model, "C12")

        let reply = """
        HTTP/1.1 200 OK\r
        Location: http://192.0.2.20/\r
        ST: urn:bambulab-com:device:3dprinter:1\r
        USN: uuid:ABC123XYZ\r
        DevName.bambu.com: X1C\r
        """
        let http = try XCTUnwrap(PrinterDiscovery.parse(reply))
        XCTAssertEqual(http.ip, "192.0.2.20")
        XCTAssertEqual(http.serial, "ABC123XYZ")
        XCTAssertEqual(http.name, "X1C")

        let tv = """
        NOTIFY * HTTP/1.1\r
        LOCATION: http://192.0.2.30:8008/ssdp/device-desc.xml\r
        NT: urn:dial-multiscreen-org:service:dial:1\r
        USN: uuid:deadbeef\r
        """
        XCTAssertNil(PrinterDiscovery.parse(tv))
        XCTAssertNil(PrinterDiscovery.parse("garbage"))
        XCTAssertNil(PrinterDiscovery.parse(""))
    }
}
