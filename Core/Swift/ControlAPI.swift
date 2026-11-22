import Foundation

/// Loopback-only control API the Finder Share Extension uses to talk to the
/// running SwiftDrop menu bar app (the extension is sandboxed; the app owns
/// discovery, the LocalSend server and all transfers).
enum ControlAPI {
    static let port: UInt16 = 53320
    static let baseURL = URL(string: "http://127.0.0.1:53320")!
    static let appURLScheme = "swiftdrop"
}

enum TransferPhase: String, Codable, Sendable {
    case idle, waiting, sending, done, declined, failed, cancelled

    var isActive: Bool { self == .waiting || self == .sending }
    var isTerminal: Bool { self == .done || self == .declined || self == .failed || self == .cancelled }

    var label: String? {
        switch self {
        case .idle: return nil
        case .waiting: return "Waiting…"
        case .sending: return "Sending…"
        case .done: return "Sent"
        case .declined: return "Declined"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct ControlDevice: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let alias: String
    let deviceType: String?
    let deviceModel: String?
    let isFavorite: Bool
    var asleep: Bool? = nil
}

struct ControlSendRequest: Codable, Sendable {
    var deviceId: String
    var paths: [String]
    var texts: [String]
}

struct ControlSendResponse: Codable, Sendable {
    let transferId: String
}

struct ControlStageResponse: Codable, Sendable {
    let path: String
}

struct ControlTransferStatus: Codable, Sendable {
    let id: String
    let deviceId: String
    let phase: TransferPhase
    let progress: Double
    let message: String?
}
