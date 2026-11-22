import Foundation
import Darwin

struct IPv4Interface {
    let name: String
    let address: in_addr
    let netmask: in_addr

    var addressString: String { Self.string(address) }

    static func string(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// Up, multicast-capable, non-loopback, non-tunnel IPv4 interfaces.
    static func all() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            if ["utun", "awdl", "llw", "lo", "gif", "stf", "anpi", "ap"].contains(where: { name.hasPrefix($0) }) { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var mask = in_addr(s_addr: 0)
            if let m = ifa.ifa_netmask {
                mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            result.append(IPv4Interface(name: name, address: sin.sin_addr, netmask: mask))
        }
        return result
    }

    /// Host addresses on this interface's subnet (capped to a /24 around us).
    func subnetHosts() -> [String] {
        let ip = UInt32(bigEndian: address.s_addr)
        var mask = UInt32(bigEndian: netmask.s_addr)
        if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
        let network = ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return (network + 1 ..< broadcast).compactMap { h in
            h == ip ? nil : IPv4Interface.string(in_addr(s_addr: h.bigEndian))
        }
    }
}

/// LocalSend multicast discovery on 224.0.0.167:53317 (BSD sockets, every interface).
final class MulticastDiscovery: @unchecked Sendable {
    var onMessage: (@Sendable (LSDeviceInfo, String) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "swiftdrop.multicast")
    private let groupAddr = inet_addr(LocalSendConstants.multicastGroup)

    func start() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LocalSendConstants.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); fd = -1; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        joinGroups()

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    /// (Re)join the group on every interface — call on network changes.
    func joinGroups() {
        guard fd >= 0 else { return }
        for iface in IPv4Interface.all() {
            var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: groupAddr), imr_interface: iface.address)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        }
    }

    func send(_ info: LSDeviceInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = LocalSendConstants.port.bigEndian
            dest.sin_addr.s_addr = self.groupAddr
            for iface in IPv4Interface.all() {
                var ifAddr = iface.address
                setsockopt(self.fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
                data.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(self.fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n <= 0 { return }
            let data = Data(buf[0..<n])
            guard let info = try? JSONDecoder().decode(LSDeviceInfo.self, from: data) else { continue }
            onMessage?(info, IPv4Interface.string(from.sin_addr))
        }
    }
}
