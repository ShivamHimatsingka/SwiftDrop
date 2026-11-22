import Foundation
import Network

/// LocalSend v2: multicast discovery + HTTP(S) server + client.
final class LocalSendTransport: NearbyTransport, @unchecked Sendable {
    let id = "localsend"
    let displayName = "LocalSend"
    let requiresCompanionAppOnPeer = true
    var isAvailable: Bool { true }

    let fingerprint: String
    let scheme: String
    private let tlsIdentity: SecIdentity?

    private weak var host: TransportHost?
    private let discovery = MulticastDiscovery()
    private var server: HTTPServer?
    private let client = LocalSendClient()
    private let sessions = ReceiveSessionStore()
    private var pathMonitor: NWPathMonitor?
    private let stateLock = NSLock()
    private var _alias = "Mac"
    private var knownPeers: [String: Peer] = [:]
    private var missCount: [String: Int] = [:]

    private var alias: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _alias }
        set { stateLock.lock(); _alias = newValue; stateLock.unlock() }
    }

    let config: LocalSendConfig

    init(config: LocalSendConfig) {
        self.config = config
        if let tls = config.tls {
            tlsIdentity = tls.identity
            fingerprint = tls.fingerprint
            scheme = "https"
        } else {
            tlsIdentity = nil
            let key = "SwiftDrop.httpFingerprint"
            if let fp = UserDefaults.standard.string(forKey: key) { fingerprint = fp }
            else {
                fingerprint = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                UserDefaults.standard.set(fingerprint, forKey: key)
            }
            scheme = "http"
        }
    }

    func myInfo(announce: Bool?) -> LSDeviceInfo {
        LSDeviceInfo(alias: alias, version: LocalSendConstants.protocolVersion, deviceModel: config.deviceModel,
                     deviceType: config.deviceType, fingerprint: fingerprint, port: Int(config.port),
                     protocol: scheme, download: false, announce: announce, announcement: announce)
    }

    // MARK: Lifecycle

    @MainActor func start(host: TransportHost) {
        self.host = host
        alias = host.deviceName

        discovery.onMessage = { [weak self] info, ip in self?.handleMulticast(info, from: ip) }
        if config.multicast {
            do { try discovery.start() } catch {
                // Not fatal: HTTP subnet scanning still finds devices.
                NSLog("SwiftDrop: multicast unavailable (\(error)); using HTTP scan")
            }
        }

        let server = HTTPServer { [weak self] req in
            guard let self else { return .notFound }
            return await self.route(req)
        }
        server.onFailure = { [weak host] msg in Task { @MainActor in host?.transportDidFail(msg) } }
        do { try server.start(port: config.port, tlsIdentity: tlsIdentity) } catch {
            host.transportDidFail("Could not listen on port \(config.port). Is LocalSend already running on this device?")
        }
        self.server = server

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            self.discovery.joinGroups()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.announceIfVisible() }
        }
        monitor.start(queue: DispatchQueue(label: "swiftdrop.path"))
        pathMonitor = monitor

        announceIfVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.announceIfVisible() }
    }

    @MainActor func stop() {
        discovery.stop()
        server?.stop()
        server = nil
        pathMonitor?.cancel()
    }

    @MainActor func setAlias(_ alias: String) {
        self.alias = alias
        announceIfVisible()
    }

    @MainActor private func announceIfVisible() {
        if host?.isDiscoverable(by: nil) == true { discovery.send(myInfo(announce: true)) }
    }

    @MainActor func refresh(deep: Bool) {
        discovery.joinGroups()
        discovery.send(myInfo(announce: true))
        let peers = stateLock.withLock { Array(knownPeers.values) }
        let me = myInfo(announce: nil)
        Task.detached { [weak self] in
            guard let self else { return }
            // Re-validate known peers (LocalSend peers do not re-announce periodically).
            await withTaskGroup(of: Void.self) { group in
                for p in peers {
                    group.addTask {
                        if let info = try? await self.client.register(base: p.baseURL, me: me, probe: true) {
                            self.ingest(info, host: p.host, port: p.port, scheme: p.scheme)
                        } else {
                            self.noteMiss(p.id)
                        }
                    }
                }
            }
            let shouldScan = deep || self.stateLock.withLock { self.knownPeers.isEmpty }
            if shouldScan { await self.scanSubnets(me: me) }
        }
    }

    private func noteMiss(_ peerID: String) {
        let drop: Bool = stateLock.withLock {
            missCount[peerID, default: 0] += 1
            if missCount[peerID]! >= 2 { knownPeers[peerID] = nil; missCount[peerID] = nil; return true }
            return false
        }
        if drop { Task { @MainActor [weak self] in self?.host?.transportDidLose(peerID) } }
    }

    /// HTTP fallback discovery for networks that drop multicast.
    private func scanSubnets(me: LSDeviceInfo) async {
        let ownIPs = Set(IPv4Interface.all().map(\.addressString))
        let hosts = Array(Set(IPv4Interface.all().flatMap { $0.subnetHosts() }).subtracting(ownIPs))
        let port = Int(LocalSendConstants.port)   // peers use the protocol default
        for batch in stride(from: 0, to: hosts.count, by: 96).map({ Array(hosts[$0..<min($0 + 96, hosts.count)]) }) {
            await withTaskGroup(of: Void.self) { group in
                for h in batch {
                    group.addTask {
                        if let (info, scheme) = await self.client.probe(host: h, port: port, me: me) {
                            self.ingest(info, host: h, port: port, scheme: scheme)
                        }
                    }
                }
            }
        }
    }

    // MARK: Discovery

    @discardableResult
    private func ingest(_ info: LSDeviceInfo, host ip: String, port: Int? = nil, scheme: String? = nil) -> Peer? {
        guard info.fingerprint != fingerprint else { return nil }
        let peer = Peer(id: info.fingerprint, transportID: id, alias: info.alias, deviceModel: info.deviceModel,
                        deviceType: info.deviceType, host: ip, port: port ?? info.port ?? Int(LocalSendConstants.port),
                        scheme: scheme ?? info.protocol ?? "https", lastSeen: Date())
        stateLock.withLock { knownPeers[peer.id] = peer; missCount[peer.id] = nil }
        Task { @MainActor [weak self] in self?.host?.transportDidUpdate(peer) }
        return peer
    }

    private func handleMulticast(_ info: LSDeviceInfo, from ip: String) {
        guard let peer = ingest(info, host: ip) else { return }
        guard info.isAnnouncement else { return }
        let me = myInfo(announce: false)
        Task { [weak self] in
            guard let self else { return }
            let visible = await MainActor.run { self.host?.isDiscoverable(by: info.fingerprint) ?? false }
            guard visible else { return }
            do { _ = try await self.client.register(base: peer.baseURL, me: me, probe: true) }
            catch { self.discovery.send(me) }   // UDP fallback response
        }
    }

    // MARK: Server routes

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        let path = req.path.replacingOccurrences(of: "/api/localsend/v1/", with: "/api/localsend/v2/")
        switch (req.method, path) {
        case ("POST", "/api/localsend/v2/register"):
            return await handleRegister(req)
        case ("GET", "/api/localsend/v2/info"):
            let visible = await MainActor.run { host?.isDiscoverable(by: req.query["fingerprint"]) ?? false }
            return visible ? .json(myInfo(announce: nil)) : .forbidden
        case ("POST", "/api/localsend/v2/prepare-upload"), ("POST", "/api/localsend/v2/send-request"):
            return await handlePrepare(req)
        case ("POST", "/api/localsend/v2/upload"), ("POST", "/api/localsend/v2/send"):
            return await handleUpload(req)
        case ("POST", "/api/localsend/v2/cancel"):
            if let ended = sessions.cancel(req.query["sessionId"]) {
                await MainActor.run { host?.transportIncomingFinished(ended.id, files: ended.finishedURLs, error: "Cancelled by sender") }
            }
            return .ok
        default:
            return .notFound
        }
    }

    private func handleRegister(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = try? await req.readBody(limit: 64 * 1024),
              let info = try? JSONDecoder().decode(LSDeviceInfo.self, from: body) else { return .badRequest }
        ingest(info, host: req.remoteHost)
        let visible = await MainActor.run { host?.isDiscoverable(by: info.fingerprint) ?? false }
        return visible ? .json(myInfo(announce: nil)) : .forbidden
    }

    private func handlePrepare(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = try? await req.readBody(limit: 64 << 20),
              let dto = try? JSONDecoder().decode(LSPrepareUploadRequest.self, from: body) else { return .badRequest }
        let sender = ingest(dto.info, host: req.remoteHost)
        let senderID = dto.info.fingerprint
        guard let host else { return .forbidden }
        let allowed = await MainActor.run { host.canReceive(from: senderID) }
        guard allowed else { return .forbidden }

        let files = dto.files.values.sorted { $0.fileName < $1.fileName }.map {
            IncomingFile(id: $0.id, name: $0.fileName, size: $0.size, mimeType: $0.fileType, preview: $0.preview)
        }
        let offer = IncomingOffer(id: UUID().uuidString, senderID: senderID, senderAlias: dto.info.alias,
                                  senderModel: dto.info.deviceModel ?? sender?.deviceModel,
                                  senderType: dto.info.deviceType, files: files)
        guard !files.isEmpty else { return .badRequest }

        if offer.isMessage {
            let text = files.compactMap(\.preview).joined(separator: "\n\n")
            await MainActor.run { host.transportDidReceiveMessage(text, offer: offer) }
            return .noContent
        }

        let saveDir = await MainActor.run { host.saveDirectory }
        if let free = try? saveDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < offer.totalBytes + 50_000_000 {
            let need = offer.totalBytes.byteString
            await MainActor.run { host.transportDidFail("Not enough disk space to receive \(need) from “\(offer.senderAlias)”.") }
            return .text("Not enough storage", status: 403)
        }
        let (reservedSlot, evicted) = sessions.reserve(senderID: senderID)
        for e in evicted {
            await MainActor.run { host.transportIncomingFinished(e.id, files: e.finishedURLs, error: "Transfer stopped") }
        }
        guard reservedSlot else { return .text("Blocked by another session", status: 409) }
        let decision = await host.transportShouldAccept(offer)
        guard decision == .accept else { sessions.release(); return .forbidden }
        let dir = await MainActor.run { host.saveDirectory }
        let session = sessions.create(offer: offer, dtos: dto.files, directory: dir, senderIP: req.remoteHost) { [weak self] s in
            Task { @MainActor in self?.host?.transportIncomingProgress(s.id, received: s.receivedBytes, total: s.totalBytes) }
        }
        return .json(LSPrepareUploadResponse(sessionId: session.id, files: session.tokens))
    }

    private func handleUpload(_ req: HTTPRequest) async -> HTTPResponse {
        guard let sid = req.query["sessionId"], let fid = req.query["fileId"], let token = req.query["token"] else {
            return .badRequest
        }
        guard let session = sessions.session(sid), session.tokens[fid] == token, let dto = session.dtos[fid] else {
            return .forbidden
        }
        let dest = session.destination(for: dto.fileName)
        let partial = dest.deletingLastPathComponent()
            .appendingPathComponent("." + dest.lastPathComponent + ".swiftdrop-part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: partial) else { return .text("Cannot write", status: 500) }
        do {
            try await req.streamBody { chunk in
                if session.isCancelled { throw TransferError.cancelled }
                try fh.write(contentsOf: chunk)
                session.add(Int64(chunk.count))
            }
            try fh.close()
            if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: partial, to: dest)
            if let m = dto.metadata?.modified, let date = ISO8601DateFormatter.lenient(m) {
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dest.path)
            }
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: partial)
            if !session.isCancelled, let ended = sessions.fail(sid) {
                await MainActor.run { host?.transportIncomingFinished(ended.id, files: ended.finishedURLs, error: "Transfer interrupted") }
            }
            return .text("Upload failed", status: 500)
        }
        if session.complete(fid, url: dest) {
            sessions.remove(sid)
            let urls = session.topLevelURLs
            await MainActor.run { host?.transportIncomingFinished(session.id, files: urls, error: nil) }
        }
        return .ok
    }

    // MARK: Sending

    func send(_ payload: OutgoingPayload, to peer: Peer, update: @escaping TransferUpdate) async throws {
        let files = try OutgoingFileCollector.collect(payload)
        guard !files.isEmpty else { throw TransferError.nothingToSend }
        update(.waiting, 0)
        let request = LSPrepareUploadRequest(info: myInfo(announce: nil),
                                             files: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.dto) }))
        let result = try await client.prepareUpload(peer: peer, request: request)
        guard case .accepted(let resp) = result else { update(.done, 1); return }

        // Largest first, up to 4 uploads in flight: small files ride alongside big ones,
        // which keeps the link saturated for folders with thousands of files.
        let accepted = files.filter { resp.files[$0.id] != nil }.sorted { $0.size > $1.size }
        let meter = ProgressMeter(total: accepted.reduce(Int64(0)) { $0 + $1.size }, update: update)
        update(.sending, 0)
        let client = self.client
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var queue = accepted[...]
                func addNext() {
                    guard let f = queue.popFirst() else { return }
                    let token = resp.files[f.id]!
                    group.addTask {
                        try await client.upload(peer: peer, sessionId: resp.sessionId, fileId: f.id,
                                                token: token, file: f.url) { sent in meter.set(f.id, sent) }
                        meter.set(f.id, f.size, force: true)
                    }
                }
                for _ in 0..<min(4, accepted.count) { addNext() }
                while try await group.next() != nil {
                    try Task.checkCancellation()
                    addNext()
                }
            }
        } catch {
            await client.cancel(peer: peer, sessionId: resp.sessionId)
            if error is CancellationError { throw TransferError.cancelled }
            throw error
        }
        update(.done, 1)
    }
}

/// Aggregates per-file byte counts and reports at most ~20×/s, so multi-GB
/// transfers don't flood the main thread with progress updates.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var perFile: [String: Int64] = [:]
    private var sent: Int64 = 0
    private var last = Date.distantPast
    private let total: Int64
    private let update: TransferUpdate

    init(total: Int64, update: @escaping TransferUpdate) {
        self.total = max(1, total)
        self.update = update
    }

    func set(_ id: String, _ bytes: Int64, force: Bool = false) {
        let report: Double? = lock.withLock {
            sent += bytes - perFile[id, default: 0]
            perFile[id] = bytes
            let now = Date()
            guard force || now.timeIntervalSince(last) > 0.05 else { return nil }
            last = now
            return min(1, Double(sent) / Double(total))
        }
        if let report { update(.sending, report) }
    }
}

extension ISO8601DateFormatter {
    static func lenient(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Config

struct LocalSendConfig {
    /// HTTP(S) port we listen on and announce (LocalSend default 53317).
    var port: UInt16 = LocalSendConstants.port
    var deviceModel: String
    /// LocalSend device type: "mobile", "desktop", "web", "headless", "server".
    var deviceType: String
    /// TLS identity + SHA-256 fingerprint; nil = plain HTTP.
    var tls: (identity: SecIdentity, fingerprint: String)?
    /// Run multicast discovery (iOS needs a special entitlement; falls back to HTTP scan).
    var multicast = true
}

// MARK: - Receive sessions

final class ReceiveSession: @unchecked Sendable {
    let id: String
    let offer: IncomingOffer
    let dtos: [String: LSFileDTO]
    let tokens: [String: String]
    let directory: URL
    let senderIP: String
    let totalBytes: Int64
    private let lock = NSLock()
    private var _received: Int64 = 0
    private var pending: Set<String>
    private var folderMap: [String: String] = [:]
    private var topLevel: [URL] = []
    private var finished: [URL] = []
    private var lastReport = Date.distantPast
    private var _lastActivity = Date()
    private let onProgress: (ReceiveSession) -> Void
    var isCancelled = false

    init(offer: IncomingOffer, dtos: [String: LSFileDTO], directory: URL, senderIP: String,
         onProgress: @escaping (ReceiveSession) -> Void) {
        self.offer = offer; self.dtos = dtos; self.directory = directory; self.senderIP = senderIP
        self.onProgress = onProgress
        id = offer.id
        tokens = Dictionary(uniqueKeysWithValues: dtos.keys.map { ($0, UUID().uuidString) })
        pending = Set(dtos.keys)
        totalBytes = dtos.values.reduce(0) { $0 + $1.size }
    }

    var receivedBytes: Int64 { lock.withLock { _received } }
    var lastActivity: Date { lock.withLock { _lastActivity } }
    var finishedURLs: [URL] { lock.withLock { finished } }
    var topLevelURLs: [URL] { lock.withLock { topLevel } }

    func add(_ n: Int64) {
        let report: Bool = lock.withLock {
            _received += n
            _lastActivity = Date()
            if Date().timeIntervalSince(lastReport) > 0.08 { lastReport = Date(); return true }
            return false
        }
        if report { onProgress(self) }
    }

    /// Returns true when the whole session is complete.
    func complete(_ fileID: String, url: URL) -> Bool {
        let done: Bool = lock.withLock {
            pending.remove(fileID)
            finished.append(url)
            return pending.isEmpty
        }
        onProgress(self)
        return done
    }

    /// Safe, unique destination. Preserves LocalSend folder structure ("Folder/sub/file").
    func destination(for rawName: String) -> URL {
        lock.withLock {
            let parts = rawName.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
                .map { $0.replacingOccurrences(of: ":", with: "-") }
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".swiftdrop") }
            let comps = parts.isEmpty ? ["File"] : parts
            let fm = FileManager.default
            if comps.count == 1 {
                let url = Self.unique(directory.appendingPathComponent(comps[0]))
                topLevel.append(url)
                return url
            }
            let root = comps[0]
            let mapped: String
            if let m = folderMap[root] { mapped = m } else {
                let u = Self.unique(directory.appendingPathComponent(root, isDirectory: true))
                mapped = u.lastPathComponent
                folderMap[root] = mapped
                topLevel.append(u)
            }
            var url = directory.appendingPathComponent(mapped, isDirectory: true)
            for c in comps.dropFirst().dropLast() { url.appendPathComponent(c, isDirectory: true) }
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return Self.unique(url.appendingPathComponent(comps.last!))
        }
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 1...9999 {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

final class ReceiveSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: ReceiveSession] = [:]
    private var reserved = false

    /// Atomically claims the single receive slot (LocalSend: one session at a time).
    /// Sessions idle for 45 s, or an older session from the same sender, are evicted
    /// so an abandoned transfer can never block the Mac.
    func reserve(senderID: String) -> (ok: Bool, evicted: [ReceiveSession]) {
        lock.withLock {
            let stale = sessions.values.filter {
                $0.offer.senderID == senderID || Date().timeIntervalSince($0.lastActivity) > 45
            }
            for s in stale { s.isCancelled = true; sessions[s.id] = nil }
            if reserved || !sessions.isEmpty { return (false, stale) }
            reserved = true
            return (true, stale)
        }
    }

    func release() { lock.withLock { reserved = false } }

    func create(offer: IncomingOffer, dtos: [String: LSFileDTO], directory: URL, senderIP: String,
                onProgress: @escaping (ReceiveSession) -> Void) -> ReceiveSession {
        let s = ReceiveSession(offer: offer, dtos: dtos, directory: directory, senderIP: senderIP, onProgress: onProgress)
        lock.withLock { sessions[s.id] = s; reserved = false }
        return s
    }

    func session(_ id: String) -> ReceiveSession? { lock.withLock { sessions[id] } }
    func remove(_ id: String) { _ = lock.withLock { sessions.removeValue(forKey: id) } }

    func cancel(_ id: String?) -> ReceiveSession? {
        lock.withLock {
            guard let id, let s = sessions.removeValue(forKey: id) else { return nil }
            s.isCancelled = true
            return s
        }
    }

    func fail(_ id: String) -> ReceiveSession? {
        lock.withLock {
            guard let s = sessions.removeValue(forKey: id) else { return nil }
            s.isCancelled = true
            return s
        }
    }
}
