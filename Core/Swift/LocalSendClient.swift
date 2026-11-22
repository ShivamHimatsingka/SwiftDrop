import Foundation
import UniformTypeIdentifiers

enum PrepareResult {
    case accepted(LSPrepareUploadResponse)
    case nothingToTransfer      // 204: e.g. text message shown on the receiver
}

/// HTTP(S) client side of LocalSend. Accepts LocalSend's self-signed certificates.
final class LocalSendClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var progressHandlers: [Int: (Int64) -> Void] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private lazy var probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.6
        c.timeoutIntervalForResource = 2.5
        c.httpMaximumConnectionsPerHost = 2
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    // MARK: Delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let h = progressHandlers[task.taskIdentifier]; lock.unlock()
        h?(totalBytesSent)
    }

    // MARK: API

    private func url(_ base: URL, _ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    private func jsonRequest<T: Encodable>(_ url: URL, _ body: T, timeout: TimeInterval) throws -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    func register(base: URL, me: LSDeviceInfo, probe: Bool = false) async throws -> LSDeviceInfo {
        let req = try jsonRequest(url(base, "/api/localsend/v2/register"), me, timeout: probe ? 1.6 : 4)
        let (data, resp) = try await (probe ? probeSession : session).data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransferError.server((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(LSDeviceInfo.self, from: data)
    }

    func prepareUpload(peer: Peer, request: LSPrepareUploadRequest) async throws -> PrepareResult {
        // The receiver may take a while to tap Accept.
        let req = try jsonRequest(url(peer.baseURL, "/api/localsend/v2/prepare-upload"), request, timeout: 600)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw TransferError.cancelled }
        catch { throw TransferError.unreachable(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200: return .accepted(try JSONDecoder().decode(LSPrepareUploadResponse.self, from: data))
        case 204: return .nothingToTransfer
        case 401: throw TransferError.pinRequired
        case 403: throw TransferError.declined
        case 409, 429: throw TransferError.busy
        default: throw TransferError.server(code)
        }
    }

    func upload(peer: Peer, sessionId: String, fileId: String, token: String, file: URL,
                progress: @escaping (Int64) -> Void) async throws {
        var req = URLRequest(url: url(peer.baseURL, "/api/localsend/v2/upload",
                                      ["sessionId": sessionId, "fileId": fileId, "token": token]),
                             timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.uploadTask(with: req, fromFile: file) { [weak self] _, resp, err in
                    if let self, let id = box.task?.taskIdentifier {
                        self.lock.lock(); self.progressHandlers[id] = nil; self.lock.unlock()
                    }
                    if let err = err as? URLError, err.code == .cancelled { cont.resume(throwing: TransferError.cancelled); return }
                    if let err { cont.resume(throwing: TransferError.unreachable(err.localizedDescription)); return }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    code == 200 ? cont.resume() : cont.resume(throwing: TransferError.server(code))
                }
                lock.lock(); progressHandlers[task.taskIdentifier] = progress; lock.unlock()
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    func cancel(peer: Peer, sessionId: String) async {
        var req = URLRequest(url: url(peer.baseURL, "/api/localsend/v2/cancel", ["sessionId": sessionId]),
                             timeoutInterval: 4)
        req.httpMethod = "POST"
        _ = try? await session.data(for: req)
    }

    /// Read a device's info without introducing ourselves (used while we're hidden).
    func info(base: URL) async throws -> LSDeviceInfo {
        let req = URLRequest(url: url(base, "/api/localsend/v2/info"), timeoutInterval: 1.6)
        let (data, resp) = try await probeSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw TransferError.server(code) }
        return try JSONDecoder().decode(LSDeviceInfo.self, from: data)
    }

    /// Probe one host the way LocalSend's HTTP fallback discovery does. When `reveal` is false
    /// (receiving off) we only read their info, so they don't learn about us.
    func probe(host: String, port: Int, me: LSDeviceInfo, reveal: Bool = true) async -> (LSDeviceInfo, String)? {
        for scheme in ["https", "http"] {
            let base = URL(string: "\(scheme)://\(host):\(port)")!
            if reveal, let info = try? await register(base: base, me: me, probe: true) { return (info, scheme) }
            if !reveal, let info = try? await info(base: base) { return (info, scheme) }
        }
        return nil
    }
}

private final class TaskBox: @unchecked Sendable { var task: URLSessionTask? }

// MARK: - Outgoing file collection

struct OutgoingFile {
    let id: String
    let name: String           // may contain "/" for folder contents (LocalSend convention)
    let url: URL
    let size: Int64
    let mime: String
    let preview: String?
    let modified: Date?

    var dto: LSFileDTO {
        let iso = ISO8601DateFormatter()
        return LSFileDTO(id: id, fileName: name, size: size, fileType: mime, sha256: nil, preview: preview,
                         metadata: modified.map { LSFileMetadata(modified: iso.string(from: $0), accessed: nil) })
    }
}

enum OutgoingFileCollector {
    /// Lossless zip of a bundle using macOS's own `ditto` (same as Finder ▸ Compress).
    static func archive(_ url: URL) throws -> URL {
        #if os(macOS)
        let dest = AppPaths.newStageFile(named: url.lastPathComponent + ".zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TransferError.unreachable("Couldn’t package \(url.lastPathComponent)") }
        return dest
        #else
        // iOS: use NSFileCoordinator's built-in zipping of directories/packages.
        var result: URL?
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordError) { zipURL in
            let dest = AppPaths.newStageFile(named: url.lastPathComponent + ".zip")
            do { try FileManager.default.copyItem(at: zipURL, to: dest); result = dest } catch { copyError = error }
        }
        if let r = result { return r }
        throw copyError ?? coordError ?? TransferError.unreachable("Couldn’t package \(url.lastPathComponent)")
        #endif
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func collect(_ payload: OutgoingPayload) throws -> [OutgoingFile] {
        var out: [OutgoingFile] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .totalFileSizeKey, .contentModificationDateKey]
        for raw in payload.fileURLs {
            let url = raw.standardizedFileURL.resolvingSymlinksInPath()
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isPackage == true {
                // Bundles (.app, .key, .pages, .rtfd, .photoslibrary…) travel as one
                // lossless archive (keeps permissions, symlinks, xattrs, resource forks).
                let zip = try archive(url)
                let zv = try zip.resourceValues(forKeys: [.fileSizeKey])
                out.append(OutgoingFile(id: UUID().uuidString, name: zip.lastPathComponent, url: zip,
                                        size: Int64(zv.fileSize ?? 0), mime: "application/zip", preview: nil,
                                        modified: v.contentModificationDate))
            } else if v.isDirectory == true {
                let rootName = url.lastPathComponent
                // Path-based enumeration yields paths relative to the root, immune to
                // /tmp ↔ /private/tmp style prefix differences.
                guard let en = FileManager.default.enumerator(atPath: url.path) else { continue }
                while let rel = en.nextObject() as? String {
                    let f = url.appendingPathComponent(rel)
                    if f.lastPathComponent == ".DS_Store" { continue }
                    let fv = try? f.resourceValues(forKeys: Set(keys))
                    if fv?.isPackage == true {
                        en.skipDescendants()
                        guard let zip = try? archive(f) else { continue }
                        let zs = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        out.append(OutgoingFile(id: UUID().uuidString, name: rootName + "/" + rel + ".zip", url: zip,
                                                size: Int64(zs), mime: "application/zip", preview: nil,
                                                modified: fv?.contentModificationDate))
                        continue
                    }
                    guard fv?.isRegularFile == true, fv?.isSymbolicLink != true else { continue }
                    out.append(OutgoingFile(id: UUID().uuidString, name: rootName + "/" + rel, url: f,
                                            size: Int64(fv?.fileSize ?? 0), mime: mime(for: f), preview: nil,
                                            modified: fv?.contentModificationDate))
                }
            } else {
                out.append(OutgoingFile(id: UUID().uuidString, name: url.lastPathComponent, url: url,
                                        size: Int64(v.fileSize ?? 0), mime: mime(for: url), preview: nil,
                                        modified: v.contentModificationDate))
            }
        }
        for text in payload.texts {
            let file = AppPaths.newStageFile(named: "message.txt")
            try Data(text.utf8).write(to: file)
            out.append(OutgoingFile(id: UUID().uuidString, name: "\(UUID().uuidString.prefix(8)).txt", url: file,
                                    size: Int64(text.utf8.count), mime: "text/plain", preview: text, modified: nil))
        }
        return out
    }
}
