import Foundation

/// Diagnostics: system log, plus a file (~/Library/Logs/SwiftDrop on macOS, the app's Caches on iOS).
enum SDLog {
    private static let queue = DispatchQueue(label: "swiftdrop.log")
    private static let handle: FileHandle? = {
        #if os(macOS)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SwiftDrop")
        #else
        // Inside the app's own container (Library/Caches) — never shown in Files.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SwiftDrop.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 { try? FileManager.default.removeItem(at: url) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
    }()
    private static let stamp: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func log(_ message: String) {
        NSLog("SwiftDrop: %@", message)
        queue.async { handle?.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8)) }
    }
}
