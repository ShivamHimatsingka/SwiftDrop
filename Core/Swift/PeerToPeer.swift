import Foundation
import Network

/// Apple peer-to-peer Wi‑Fi (AWDL — the link AirDrop uses) via Network.framework.
/// Mac ↔ iPhone/iPad get their own Wi‑Fi link without leaving their current
/// network, so transfers work even with no shared Wi‑Fi or a slow router.
enum P2P {
    static let serviceType = "_swiftdrop._tcp"

    static func parameters(tls: Bool, server identity: SecIdentity? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params: NWParameters
        if tls {
            let t = NWProtocolTLS.Options()
            if let identity, let sec = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(t.securityProtocolOptions, sec)
            }
            sec_protocol_options_set_min_tls_protocol_version(t.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(t.securityProtocolOptions, .TLSv12)
            // SwiftDrop peers use self-signed certificates (as LocalSend does).
            sec_protocol_options_set_verify_block(t.securityProtocolOptions, { _, _, done in done(true) },
                                                  DispatchQueue.global())
            params = NWParameters(tls: t, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.includePeerToPeer = true
        return params
    }

    static func txt(fingerprint: String, alias: String, model: String, type: String, scheme: String, port: Int) -> NWTXTRecord {
        var r = NWTXTRecord()
        r["f"] = fingerprint; r["a"] = String(alias.prefix(60)); r["m"] = model; r["t"] = type
        r["s"] = scheme; r["p"] = "\(port)"
        return r
    }
}

/// Browses for SwiftDrop services on Wi‑Fi *and* peer-to-peer links.
final class P2PBrowser: @unchecked Sendable {
    /// Peer-to-peer interface (awdl0) each service was seen on, for pinning direct connections.
    static let interfaces = InterfaceMap()

    struct Found: Sendable {
        let serviceName: String
        let fingerprint: String
        let alias: String
        let model: String?
        let type: String?
        let scheme: String
        let isPeerToPeer: Bool
    }
    var onChange: (@Sendable ([Found]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "swiftdrop.p2p.browse")

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: P2P.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Found] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint,
                      case .bonjour(let txt) = r.metadata, let fp = txt["f"] else { return nil }
                let awdl = r.interfaces.first { $0.name.hasPrefix("awdl") }
                P2PBrowser.interfaces.set(name, awdl)
                let p2p = awdl != nil
                return Found(serviceName: name, fingerprint: fp, alias: txt["a"] ?? name, model: txt["m"],
                             type: txt["t"], scheme: txt["s"] ?? "https", isPeerToPeer: p2p)
            }
            self?.onChange?(found)
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}

/// Minimal HTTP/1.1 client over NWConnection to a Bonjour service (works over AWDL,
/// which URLSession can't use). One request per connection.
enum P2PHTTP {
    enum Body { case none, data(Data), file(URL) }

    /// Resolved address per service: Bonjour resolution can take seconds, so do it once per transfer.
    private static let cache = ResolvedCache()

    static func request(service: String, tls: Bool, method: String, path: String, query: [String: String] = [:],
                        body: Body = .none, contentType: String = "application/json", timeout: TimeInterval = 30,
                        peerToPeerOnly: Bool = false, progress: ((Int64) -> Void)? = nil) async throws -> (Int, Data) {
        let awdl = peerToPeerOnly ? P2PBrowser.interfaces.get(service) : nil
        if let hit = cache.get(service), awdl == nil || hit.interface?.name == awdl?.name {
            do {
                return try await perform(endpoint: hit.endpoint, interface: hit.interface, service: service, tls: tls, method: method,
                                         path: path, query: query, body: body, contentType: contentType, timeout: timeout, progress: progress)
            } catch is CancellationError { throw TransferError.cancelled }
            catch { cache.remove(service) }   // address went stale (e.g. AWDL re-negotiated): resolve again
        }
        return try await perform(endpoint: .service(name: service, type: P2P.serviceType, domain: "local.", interface: awdl),
                                 interface: awdl, service: service, tls: tls, method: method, path: path, query: query,
                                 body: body, contentType: contentType, timeout: timeout, progress: progress)
    }

    private static func perform(endpoint: NWEndpoint, interface: NWInterface?, service: String, tls: Bool, method: String,
                                path: String, query: [String: String], body: Body, contentType: String, timeout: TimeInterval,
                                progress: ((Int64) -> Void)?) async throws -> (Int, Data) {
        let params = P2P.parameters(tls: tls)
        if let interface { params.requiredInterface = interface }
        let conn = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "swiftdrop.p2p.http")
        defer { conn.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .service = endpoint, let path = conn.currentPath, let remote = path.remoteEndpoint {
                        let iface = path.availableInterfaces.first
                        cache.set(service, remote, iface)
                        SDLog.log("direct link to \(service) via \(iface?.name ?? "?")")
                    }
                    once.run { c.resume() }
                case .failed(let e): once.run { c.resume(throwing: e) }
                case .waiting(let e): once.run { c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: TransferError.cancelled) }
                default: break
                }
            }
            conn.start(queue: queue)
            // Connecting (Bonjour resolve + bringing up AWDL) gets 10 s; the caller falls back to Wi‑Fi.
            queue.asyncAfter(deadline: .now() + min(timeout, 10)) { once.run { c.resume(throwing: TransferError.unreachable("Direct link timed out")) } }
        }

        var target = path
        if !query.isEmpty {
            var comps = URLComponents(); comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            target += "?" + (comps.percentEncodedQuery ?? "")
        }
        let length: Int64
        switch body {
        case .none: length = 0
        case .data(let d): length = Int64(d.count)
        case .file(let u): length = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let head = "\(method) \(target) HTTP/1.1\r\nHost: swiftdrop\r\nContent-Type: \(contentType)\r\n" +
                   "Content-Length: \(length)\r\nConnection: close\r\n\r\n"
        try await send(conn, Data(head.utf8))
        switch body {
        case .none: break
        case .data(let d): try await send(conn, d)
        case .file(let u):
            let fh = try FileHandle(forReadingFrom: u)
            defer { try? fh.close() }
            var sent: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try await send(conn, chunk)
                sent += Int64(chunk.count)
                progress?(sent)
            }
        }
        return try await readResponse(conn, timeout: timeout)
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in e.map { c.resume(throwing: $0) } ?? c.resume() })
        }
    }

    private static func receive(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: (d, done)) }
            }
        }
    }

    private static func readResponse(_ conn: NWConnection, timeout: TimeInterval) async throws -> (Int, Data) {
        var buf = Data()
        let sep = Data("\r\n\r\n".utf8)
        while buf.range(of: sep) == nil {
            let (d, done) = try await receive(conn)
            if let d { buf.append(d) }
            if done && buf.range(of: sep) == nil { throw TransferError.unreachable("Connection closed") }
        }
        let r = buf.range(of: sep)!
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
        var body = Data(buf[r.upperBound...])
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? -1
        let len = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        while body.count < len {
            let (d, done) = try await receive(conn)
            if let d { body.append(d) }
            if done { break }
        }
        return (status, body)
    }
}

final class InterfaceMap: @unchecked Sendable {
    private let lock = NSLock(); private var map: [String: NWInterface] = [:]
    func set(_ k: String, _ v: NWInterface?) { lock.withLock { map[k] = v } }
    func get(_ k: String) -> NWInterface? { lock.withLock { map[k] } }
}

private final class ResolvedCache: @unchecked Sendable {
    struct Entry { let endpoint: NWEndpoint; let interface: NWInterface?; let at: Date }
    private let lock = NSLock(); private var map: [String: Entry] = [:]
    func get(_ k: String) -> Entry? {
        lock.withLock { map[k].flatMap { Date().timeIntervalSince($0.at) < 120 ? $0 : nil } }
    }
    func set(_ k: String, _ e: NWEndpoint, _ i: NWInterface?) { lock.withLock { map[k] = Entry(endpoint: e, interface: i, at: Date()) } }
    func remove(_ k: String) { lock.withLock { map[k] = nil } }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
}
