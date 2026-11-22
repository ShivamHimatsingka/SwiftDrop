import Foundation
import Security
import CryptoKit

/// iOS can't shell out to openssl, so we build a self-signed X.509 (ECDSA P-256)
/// certificate in-process, keep the key + cert in the app's Keychain, and hand
/// Network.framework the resulting SecIdentity. Fingerprint = SHA-256(DER cert),
/// matching LocalSend.
enum TLSIdentityStore {
    private static let label = "SwiftDrop TLS"
    private static let keyTag = Data("com.swiftdrop.tls.key".utf8)

    /// Readable while the phone is locked (after the first unlock since boot), so a background
    /// relaunch for a Bluetooth knock can still use our identity.
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Our long-lived identity. Returns nil only if the Keychain can't be read right now
    /// (phone restarted and not unlocked yet). In that case nothing is created or deleted,
    /// so the identity — and how other devices know this iPhone — never changes.
    static func loadOrCreate() -> (identity: SecIdentity, fingerprint: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                kSecReturnRef as String: true]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            let identity = out as! SecIdentity
            migrateAccessibility()
            guard let fp = fingerprint(of: identity) else { return nil }
            SDLog.log("TLS identity loaded (\(fp.prefix(8)))")
            return (identity, fp)
        case errSecItemNotFound:
            guard let created = create() else { SDLog.log("TLS identity: creation failed"); return nil }
            SDLog.log("TLS identity created (\(created.1.prefix(8)))")
            return created
        default:
            SDLog.log("TLS identity not readable yet (status \(status)); waiting for unlock")
            return nil
        }
    }

    /// Identities created by older builds were "when unlocked" only.
    private static func migrateAccessibility() {
        let update = [kSecAttrAccessible as String: accessible] as CFDictionary
        SecItemUpdate([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary, update)
        SecItemUpdate([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary, update)
    }

    private static func fingerprint(of identity: SecIdentity) -> String? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func existing() -> (SecIdentity, String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                kSecReturnRef as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let out else { return nil }
        let identity = out as! SecIdentity
        return fingerprint(of: identity).map { (identity, $0) }
    }

    private static func create() -> (SecIdentity, String)? {
        // Clean leftovers from a partial run.
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrApplicationTag as String: keyTag,
                                            kSecAttrLabel as String: label,
                                            kSecAttrAccessible as String: accessible],
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(priv),
              let pubData = SecKeyCopyExternalRepresentation(pub, &err) as Data? else { return nil }

        let tbs = DER.tbsCertificate(publicKey: pubData)
        guard let sig = SecKeyCreateSignature(priv, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &err) as Data? else {
            return nil
        }
        let certDER = DER.seq([tbs, DER.ecdsaSHA256, DER.bitString(sig)])
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else { return nil }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert,
                                  kSecAttrLabel as String: label, kSecAttrAccessible as String: accessible]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else { return nil }
        return existing()
    }
}

/// Just enough DER to express one certificate.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var d = Data([tag])
        let n = content.count
        if n < 0x80 { d.append(UInt8(n)) }
        else if n <= 0xFF { d.append(contentsOf: [0x81, UInt8(n)]) }
        else { d.append(contentsOf: [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]) }
        d.append(content)
        return d
    }
    static func seq(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static func bitString(_ d: Data) -> Data { tlv(0x03, Data([0]) + d) }
    static func utf8(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    static func integer(_ d: Data) -> Data {
        var v = d
        while v.count > 1, v.first == 0 { v.removeFirst() }
        if let f = v.first, f & 0x80 != 0 { v.insert(0, at: 0) }
        return tlv(0x02, v)
    }
    static func utcTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }

    // 1.2.840.10045.4.3.2 ecdsa-with-SHA256
    static let ecdsaSHA256 = seq([oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])])

    static func tbsCertificate(publicKey: Data) -> Data {
        let name = seq([set([seq([oid([0x55, 0x04, 0x03]), utf8("SwiftDrop")])])])  // CN=SwiftDrop
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) }); serial[0] &= 0x7F
        let now = Date()
        let validity = seq([utcTime(now.addingTimeInterval(-86400)), utcTime(now.addingTimeInterval(10 * 365 * 86400))])
        let spki = seq([
            seq([oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),          // id-ecPublicKey
                 oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])]),  // prime256v1
            bitString(publicKey),
        ])
        let version = tlv(0xA0, integer(Data([2])))
        return seq([version, integer(serial), ecdsaSHA256, name, validity, name, spki])
    }
}
