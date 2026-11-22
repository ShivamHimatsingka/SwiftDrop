import Foundation
import Security
import CryptoKit

/// Self-signed TLS identity used for LocalSend's HTTPS mode. The fingerprint
/// LocalSend expects is the SHA-256 of the certificate (DER).
enum TLSIdentityStore {
    private static let passphrase = "swiftdrop"

    static func loadOrCreate() -> (identity: SecIdentity, fingerprint: String)? {
        let p12 = AppPaths.support.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            guard generate(into: p12) else { return nil }
        }
        if let loaded = load(p12) { return loaded }
        // Corrupt / unreadable: regenerate once.
        try? FileManager.default.removeItem(at: p12)
        guard generate(into: p12) else { return nil }
        return load(p12)
    }

    private static func load(_ url: URL) -> (SecIdentity, String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let raw = array.first?[kSecImportItemIdentity as String] else { return nil }
        let identity = raw as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return (identity, fp)
    }

    private static func generate(into p12: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("swiftdrop-tls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = tmp.appendingPathComponent("key.pem").path
        let cert = tmp.appendingPathComponent("cert.pem").path
        let cn = "SwiftDrop-\(UUID().uuidString.prefix(8))"
        let ok1 = run(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "3650",
                       "-keyout", key, "-out", cert, "-subj", "/CN=\(cn)"])
        guard ok1 else { return false }
        let ok2 = run(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path,
                       "-passout", "pass:\(passphrase)", "-name", "SwiftDrop",
                       "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        if ok2 { chmod(p12.path, 0o600) }
        return ok2
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
