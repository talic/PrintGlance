import Darwin
import Foundation

/// Bambu SSDP on UDP 1990/2021 multicast. Access code is never in the packet.
enum PrinterDiscovery {
    struct Hit: Equatable, Hashable, Identifiable, Sendable {
        var ip: String
        var serial: String
        var name: String
        var model: String

        var id: String { serial.isEmpty ? ip : serial }
    }

    static let timeout: TimeInterval = 4

    static func parse(_ packet: String) -> Hit? {
        var location = ""
        var usn = ""
        var name = ""
        var model = ""
        var nt = ""
        var st = ""
        for raw in packet.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "location": location = value
            case "usn": usn = value
            case "devname.bambu.com": name = value
            case "devmodel.bambu.com": model = value
            case "nt": nt = value
            case "st": st = value
            default: break
            }
        }
        guard let ip = host(fromLocation: location) else { return nil }
        let bambu = nt.localizedCaseInsensitiveContains("bambulab")
            || st.localizedCaseInsensitiveContains("bambulab")
            || !name.isEmpty
            || !model.isEmpty
        guard bambu else { return nil }
        return Hit(ip: ip, serial: serial(fromUSN: usn), name: name, model: model)
    }

    static func scan(timeout: TimeInterval = timeout) async -> [Hit] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: collect(timeout: timeout))
            }
        }
    }

    private static let multicast = "239.255.255.250"
    private static let ports: [UInt16] = [1990, 2021]
    private static let msearch = Data(
        """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1990\r
        MAN: "ssdp:discover"\r
        ST: urn:bambulab-com:device:3dprinter:1\r
        MX: 3\r
        \r

        """.utf8
    )

    private static func host(fromLocation raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let url = URL(string: s), let host = url.host, !host.isEmpty {
            return Self.isPrinterAddress(host) ? host : nil
        }
        let host = s.split(separator: "/").first.map(String.init) ?? s
        return Self.isPrinterAddress(host) ? host : nil
    }

    private static func isPrinterAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        if host.hasPrefix("239.") || host == "255.255.255.255" || host == "0.0.0.0" {
            return false
        }
        return true
    }

    private static func serial(fromUSN raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("uuid:") {
            return String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if let range = s.range(of: "::", options: .backwards) {
            return String(s[range.upperBound...])
        }
        return s
    }

    private static func collect(timeout: TimeInterval) -> [Hit] {
        var fds: [Int32] = []
        for port in ports {
            if let fd = udpSocket(port: port) { fds.append(fd) }
        }
        if let fd = udpSocket(port: 0) { fds.append(fd) }
        guard !fds.isEmpty else { return [] }

        let lock = NSLock()
        var hits: [String: Hit] = [:]
        let queue = DispatchQueue(label: "local.PrintGlance.ssdp")
        let sources: [DispatchSourceRead] = fds.map { fd in
            sendMSearch(fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return }
                let text = String(bytes: buf[0..<n], encoding: .utf8)
                    ?? String(bytes: buf[0..<n], encoding: .ascii)
                guard let text, let hit = parse(text) else { return }
                lock.lock()
                hits[hit.id] = hit
                lock.unlock()
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            return src
        }

        Thread.sleep(forTimeInterval: timeout)
        sources.forEach { $0.cancel() }
        lock.lock()
        let result = hits.values.sorted {
            ($0.name, $0.ip, $0.serial) < ($1.name, $1.ip, $1.serial)
        }
        lock.unlock()
        return result
    }

    private static func udpSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            close(fd)
            return nil
        }
        var mreq = ip_mreq()
        inet_pton(AF_INET, multicast, &mreq.imr_multiaddr)
        mreq.imr_interface.s_addr = INADDR_ANY
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
        return fd
    }

    private static func sendMSearch(_ fd: Int32) {
        for port in ports {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, multicast, &addr.sin_addr)
            msearch.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(
                            fd, base, msearch.count, 0, $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
        }
    }
}
