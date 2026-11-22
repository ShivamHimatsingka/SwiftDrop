import Foundation
import Network

/// Minimal, streaming HTTP/1.1 server on Network.framework (optional TLS).
/// Supports keep-alive, Content-Length and chunked request bodies, and
/// streams uploads straight to disk without buffering whole files.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "swiftdrop.http", qos: .userInitiated, attributes: .concurrent)
    private let handler: Handler
    var onFailure: (@Sendable (String) -> Void)?
    /// The system tore the listener down (iOS, app paused). Restart when back in the foreground.
    var onDefunct: (@Sendable () -> Void)?

    init(handler: @escaping Handler) { self.handler = handler }

    func start(port: UInt16, tlsIdentity: SecIdentity?, loopbackOnly: Bool = false,
               peerToPeer: Bool = false, service: NWListener.Service? = nil) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params: NWParameters
        if let identity = tlsIdentity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            #if os(iOS)
            // iOS's server-side TLS 1.3 stalls after the handshake with a Keychain
            // EC identity (application data never arrives). TLS 1.2 is solid and
            // supported by every LocalSend client.
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            #endif
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = peerToPeer    // accept connections over AWDL too
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let l: NWListener
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            params.acceptLocalOnly = true
            l = try NWListener(using: params)
        } else {
            l = try NWListener(using: params, on: nwPort)
        }
        l.service = service
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            HTTPConnection(conn, queue: self.queue, handler: self.handler).start()
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready: SDLog.log("listener on \(port) ready")
            case .waiting(let e): SDLog.log("listener on \(port) waiting: \(e)")
            case .failed(let e): SDLog.log("listener on \(port) failed: \(e)")
            default: break
            }
            guard let self, case .failed(let err) = state, let l, l === self.listener else { return }  // ignore old listeners
            // iOS tears listeners down while the app is paused ("DefunctConnection"); the app
            // restarts it on resume, so that's not an error worth showing.
            if "\(err)".contains("Defunct") || "\(err)".contains("-65569") {
                SDLog.log("listener on \(port) was shut down while paused")
                self.onDefunct?()
                return
            }
            self.onFailure?("Port \(port): \(err.localizedDescription)")
        }
        listener = l
        l.start(queue: queue)
    }

    /// Show/hide the Bonjour (and peer-to-peer) advertisement, e.g. when receiving is turned off.
    func setService(_ service: NWListener.Service?) { listener?.service = service }

    func stop(then: (@Sendable () -> Void)? = nil) {
        onFailure = nil; onDefunct = nil
        guard let l = listener else { then?(); return }
        listener = nil
        if let then {
            // Call back once the port is really released (or after 1 s at most).
            let once = OnceFlag()
            l.stateUpdateHandler = { state in if case .cancelled = state { once.run(then) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { once.run(then) }
        }
        l.cancel()
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ s: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"],
                     body: Data("{\"message\":\"\(s)\"}".utf8))
    }

    static let ok = HTTPResponse(status: 200)
    static let noContent = HTTPResponse(status: 204)
    static let notFound = HTTPResponse.text("Not found", status: 404)
    static let badRequest = HTTPResponse.text("Bad request", status: 400)
    static let forbidden = HTTPResponse.text("Forbidden", status: 403)

    static func reason(_ code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default: return code < 400 ? "OK" : "Internal Server Error"
        }
    }
}

enum HTTPError: Error { case closed, malformed, tooLarge }

final class HTTPRequest: @unchecked Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lower-cased names
    let remoteHost: String
    fileprivate unowned let connection: HTTPConnection
    fileprivate var bodyConsumed = false

    fileprivate init(method: String, path: String, query: [String: String], headers: [String: String],
                     remoteHost: String, connection: HTTPConnection) {
        self.method = method; self.path = path; self.query = query
        self.headers = headers; self.remoteHost = remoteHost; self.connection = connection
    }

    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }

    func readBody(limit: Int = 1 << 20) async throws -> Data {
        var out = Data()
        try await streamBody { chunk in
            out.append(chunk)
            if out.count > limit { throw HTTPError.tooLarge }
        }
        return out
    }

    /// Streams the request body to `sink`. Can only be called once.
    func streamBody(_ sink: (Data) throws -> Void) async throws {
        guard !bodyConsumed else { return }
        bodyConsumed = true
        try await connection.streamBody(of: self, sink)
    }
}

final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var sawEOF = false

    init(_ conn: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.conn = conn; self.queue = queue; self.handler = handler
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.conn.stateUpdateHandler = nil
            default: break
            }
        }
        conn.start(queue: queue)
        Task { await self.serve() }
    }

    private var remoteHost: String {
        if case .hostPort(let host, _) = conn.endpoint {
            var s: String
            switch host {
            case .ipv4(let a): s = "\(a)"
            case .ipv6(let a): s = "\(a)"
            case .name(let n, _): s = n
            @unknown default: s = "\(host)"
            }
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
            if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
            return s
        }
        return "0.0.0.0"
    }

    private func serve() async {
        defer { conn.cancel() }
        while true {
            guard let request = try? await readHead() else { return }
            let response = await handler(request)
            // Drain any unread body so the connection can be reused (small bodies only).
            if !request.bodyConsumed {
                if let len = request.contentLength, len > 4 << 20 {
                    try? await send(response, close: true); return
                }
                do { try await request.streamBody { _ in } } catch { return }
            }
            let close = request.headers["connection"]?.lowercased() == "close"
            do { try await send(response, close: close) } catch { return }
            if close { return }
        }
    }

    // MARK: Reading

    /// `atLeast` lets body streaming wait for big batches (fewer wakeups and
    /// fewer, larger disk writes) instead of one hop per 16 KB TLS record.
    private func receive(atLeast: Int = 1) async throws -> Data? {
        if sawEOF { return nil }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: max(1, atLeast), maximumLength: 4 * 1024 * 1024) { [weak self] data, _, isComplete, error in
                if isComplete { self?.sawEOF = true }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: isComplete ? nil : Data())
            }
        }
    }

    private func fill() async throws {
        guard let d = try await receive() else { throw HTTPError.closed }
        buffer.append(d)
    }

    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    private func readHead() async throws -> HTTPRequest {
        while true {
            if let r = buffer.range(of: Self.crlfcrlf) {
                let headData = buffer[buffer.startIndex..<r.lowerBound]
                buffer = Data(buffer[r.upperBound...])
                guard let head = String(data: headData, encoding: .utf8) else { throw HTTPError.malformed }
                return try parse(head)
            }
            if buffer.count > 64 * 1024 { throw HTTPError.tooLarge }
            try await fill()
        }
    }

    private func parse(_ head: String) throws -> HTTPRequest {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw HTTPError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let target = String(requestLine[1])
        let comps = URLComponents(string: "http://x" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: comps?.path ?? target,
                           query: query, headers: headers, remoteHost: remoteHost, connection: self)
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Self.crlf) {
                let line = String(data: buffer[buffer.startIndex..<r.lowerBound], encoding: .utf8) ?? ""
                buffer = Data(buffer[r.upperBound...])
                return line
            }
            if buffer.count > 16 * 1024 { throw HTTPError.malformed }
            try await fill()
        }
    }

    /// Delivers exactly `count` bytes to `sink`, avoiding copies for large reads.
    private func pump(_ count: Int64, _ sink: (Data) throws -> Void) async throws {
        var remaining = count
        if !buffer.isEmpty {
            let take = Int(min(Int64(buffer.count), remaining))
            try sink(buffer.prefix(take))
            buffer = take == buffer.count ? Data() : Data(buffer.dropFirst(take))
            remaining -= Int64(take)
        }
        while remaining > 0 {
            guard let d = try await receive(atLeast: Int(min(remaining, 1 << 20))) else { throw HTTPError.closed }
            if d.isEmpty { continue }
            if Int64(d.count) <= remaining {
                try sink(d)
                remaining -= Int64(d.count)
            } else {
                let take = Int(remaining)
                try sink(d.prefix(take))
                buffer = Data(d.dropFirst(take))
                remaining = 0
            }
        }
    }

    fileprivate func streamBody(of request: HTTPRequest, _ sink: (Data) throws -> Void) async throws {
        if request.headers["expect"]?.lowercased() == "100-continue" {
            try await sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        if request.isChunked {
            while true {
                let sizeLine = try await readLine()
                let hex = sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int64(hex, radix: 16) else { throw HTTPError.malformed }
                if size == 0 {
                    while try await readLine() != "" {}   // trailers
                    return
                }
                try await pump(size, sink)
                _ = try await readLine()
            }
        } else if let len = request.contentLength, len > 0 {
            try await pump(len, sink)
        }
    }

    // MARK: Writing

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func send(_ r: HTTPResponse, close: Bool) async throws {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        var headers = r.headers
        headers["Content-Length"] = "\(r.body.count)"
        headers["Connection"] = close ? "close" : "keep-alive"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(r.body)
        try await sendRaw(data)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ f: () -> Void) { lock.lock(); let go = !done; done = true; lock.unlock(); if go { f() } }
}
