import Foundation
import Security

struct KeychainStore: Sendable {
    static let shared = KeychainStore(service: "com.ryancalpin.pocketrig.identity")
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    /// Returns nil only when the item does not exist; any other failure throws.
    func readThrowing(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw PairingCryptoError.failed("keychain read \(status)")
        }
        return data
    }
    func read(_ account: String) -> Data? { try? readThrowing(account) }
    func write(_ data: Data, account: String) throws {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingCryptoError.failed("keychain \(status)") }
    }
    func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

struct ClientIdentity: Sendable {
    static let p12Password = "pocketrig"
    let certPEM: Data
    let keyPEM: Data
    let p12: Data
    let uniqueID: String

    /// Serializes creation so two first launches can't each write part of a different identity.
    private static let creationLock = NSLock()

    /// True when `keyPEM` is the private key for `certPEM` (a signature made with one verifies with the other).
    static func keyMatchesCert(keyPEM: Data, certPEM: Data) -> Bool {
        let probe = PairingCrypto.randomBytes(32)
        guard let signature = try? PairingCrypto.sign(probe, keyPEM: keyPEM) else { return false }
        return (try? PairingCrypto.verify(probe, signature: signature, certPEM: certPEM)) == true
    }

    static func loadOrCreate(store: KeychainStore = .shared) throws -> ClientIdentity {
        creationLock.lock()
        defer { creationLock.unlock() }
        let c = try store.readThrowing("cert"), k = try store.readThrowing("key")
        let p = try store.readThrowing("p12"), u = try store.readThrowing("uniqueid")
        // Partial or mismatched state is corrupt: fall through and regenerate all four.
        if let c, let k, let p, let u, keyMatchesCert(keyPEM: k, certPEM: c) {
            return ClientIdentity(certPEM: c, keyPEM: k, p12: p, uniqueID: String(decoding: u, as: UTF8.self))
        }
        let generated = try PairingCrypto.generateIdentity(p12Password: p12Password)
        let unique = PairingCrypto.randomBytes(8).hexString.uppercased()
        try store.write(generated.certPEM, account: "cert")
        try store.write(generated.keyPEM, account: "key")
        try store.write(generated.p12, account: "p12")
        try store.write(Data(unique.utf8), account: "uniqueid")
        return ClientIdentity(certPEM: generated.certPEM, keyPEM: generated.keyPEM, p12: generated.p12, uniqueID: unique)
    }

    func secIdentity() throws -> SecIdentity {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData,
                                     [kSecImportExportPassphrase as String: Self.p12Password] as CFDictionary,
                                     &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw PairingCryptoError.failed("p12 import \(status)")
        }
        guard CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw PairingCryptoError.failed("p12 import: not an identity")
        }
        return unsafeDowncast(identity as AnyObject, to: SecIdentity.self)
    }
}
