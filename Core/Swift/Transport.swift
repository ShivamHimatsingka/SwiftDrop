import Foundation

// MARK: - Transport abstraction
//
// SwiftDrop is built around pluggable "nearby" transports. Today it ships the
// LocalSend v2 transport (works with every LocalSend app on Android, Windows,
// Linux, iOS and macOS). The abstraction exists so OS-native transports that
// need *no app at all* on the receiving device (e.g. Android/Windows Quick Share)
// can be added without touching the UI. See docs/NativeReceiving.md.

struct Peer: Identifiable, Hashable, Sendable {
    let id: String              // stable per device (LocalSend: fingerprint)
    var transportID: String
    var alias: String
    var deviceModel: String?
    var deviceType: String?
    var host: String
    var port: Int
    var scheme: String
    var lastSeen: Date
    /// Bonjour service name when reachable over Apple peer-to-peer Wi‑Fi (AWDL).
    var awdlService: String? = nil

    var hasLAN: Bool { !host.isEmpty }
    var baseURL: URL { URL(string: "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)")! }
}

struct OutgoingPayload: Sendable {
    var fileURLs: [URL] = []
    var texts: [String] = []

    var isEmpty: Bool { fileURLs.isEmpty && texts.isEmpty }

    var summary: String {
        if fileURLs.isEmpty {
            if texts.count == 1 { return "“\(texts[0].prefix(40).trimmingCharacters(in: .whitespacesAndNewlines))”" }
            return "\(texts.count) Messages"
        }
        if fileURLs.count == 1, texts.isEmpty { return fileURLs[0].lastPathComponent }
        return "\(fileURLs.count + texts.count) Items"
    }
}

struct IncomingFile: Sendable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let mimeType: String
    let preview: String?
}

struct IncomingOffer: Sendable, Identifiable {
    let id: String
    let senderID: String
    let senderAlias: String
    let senderModel: String?
    let senderType: String?
    let files: [IncomingFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// LocalSend sends plain text as a single text/plain "file" carrying a preview.
    var isMessage: Bool {
        !files.isEmpty && files.allSatisfy { $0.mimeType.hasPrefix("text/plain") && $0.preview != nil }
    }

    var headline: String {
        if files.count == 1 { return files[0].name }
        let images = files.filter { $0.mimeType.hasPrefix("image/") }.count
        if images == files.count { return "\(files.count) Photos" }
        return "\(files.count) Items"
    }
}

enum IncomingDecision: Sendable { case accept, decline }

enum TransferError: LocalizedError {
    case declined, busy, pinRequired, unreachable(String), server(Int), cancelled, nothingToSend

    var errorDescription: String? {
        switch self {
        case .declined: return "Declined"
        case .busy: return "Device is busy"
        case .pinRequired: return "Device requires a PIN"
        case .unreachable(let m): return "Unreachable: \(m)"
        case .server(let c): return "Error \(c)"
        case .cancelled: return "Cancelled"
        case .nothingToSend: return "Nothing to send"
        }
    }
}

/// Everything a transport needs from the app. Main-actor isolated.
@MainActor protocol TransportHost: AnyObject {
    var deviceName: String { get }
    var saveDirectory: URL { get }
    var receiveMode: ReceiveMode { get }
    /// Whether we should answer discovery from this device.
    func isDiscoverable(by peerID: String?) -> Bool
    /// Whether incoming transfers from this device are allowed at all (receive mode).
    func canReceive(from peerID: String) -> Bool
    func transportDidUpdate(_ peer: Peer)
    func transportDidLose(_ peerID: String)
    func transportShouldAccept(_ offer: IncomingOffer) async -> IncomingDecision
    func transportDidReceiveMessage(_ text: String, offer: IncomingOffer)
    func transportIncomingProgress(_ offerID: String, received: Int64, total: Int64)
    func transportIncomingFinished(_ offerID: String, files: [URL], error: String?)
    func transportDidFail(_ message: String)
}

typealias TransferUpdate = @Sendable (TransferPhase, Double) -> Void

protocol NearbyTransport: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// false for OS-native transports (Quick Share): nothing to install or open on the peer.
    var requiresCompanionAppOnPeer: Bool { get }
    var isAvailable: Bool { get }

    @MainActor func start(host: TransportHost)
    @MainActor func stop()
    @MainActor func setAlias(_ alias: String)
    /// Announce ourselves and re-validate known peers. `deep` adds a subnet scan.
    @MainActor func refresh(deep: Bool)
    func send(_ payload: OutgoingPayload, to peer: Peer, update: @escaping TransferUpdate) async throws
}
