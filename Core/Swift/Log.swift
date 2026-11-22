import Foundation

/// Diagnostics: system log everywhere, plus ~/Library/Logs/SwiftDrop/SwiftDrop.log on macOS.
enum SDLog {
    #if os(macOS)
    private static let queue = DispatchQueue(label: "swiftdrop.log")
    private static let handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SwiftDrop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SwiftDrop.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 { try? FileManager.default.removeItem(at: url) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
    }()
    private static let stamp: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    #endif

    static func log(_ message: String) {
        NSLog("SwiftDrop: %@", message)
        #if os(macOS)
        queue.async { handle?.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8)) }
        #endif
    }
}
