import Foundation

// MARK: - LocalSend v2 wire format
// https://github.com/localsend/protocol

struct LSDeviceInfo: Codable, Sendable {
    var alias: String
    var version: String?
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int?
    var `protocol`: String?
    var download: Bool?
    var announce: Bool?
    var announcement: Bool?   // v1 compatibility

    var isAnnouncement: Bool { announce == true || announcement == true }
}

struct LSFileMetadata: Codable, Sendable {
    var modified: String?
    var accessed: String?
}

struct LSFileDTO: Codable, Sendable {
    var id: String
    var fileName: String
    var size: Int64
    var fileType: String
    var sha256: String?
    var preview: String?
    var metadata: LSFileMetadata?
}

struct LSPrepareUploadRequest: Codable, Sendable {
    var info: LSDeviceInfo
    var files: [String: LSFileDTO]
}

struct LSPrepareUploadResponse: Codable, Sendable {
    var sessionId: String
    var files: [String: String]
}

enum LocalSendConstants {
    static let protocolVersion = "2.1"
    static let multicastGroup = "224.0.0.167"
    static let port: UInt16 = 53317
}
