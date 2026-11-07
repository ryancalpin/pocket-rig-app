import Foundation
import CryptoKit
import CMoonlight

enum PairingCryptoError: Error { case failed(String) }

enum PairingCrypto {
    private static func take(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Data {
        guard let ptr else { return Data() }
        defer { PRFree(ptr) }
        return Data(bytes: ptr, count: len)
    }

    private static func takeSecure(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Data {
        guard let ptr else { return Data() }
        defer { PRFreeSecure(ptr, len) }
        return Data(bytes: ptr, count: len)
    }

    static func generateIdentity(p12Password: String) throws -> (certPEM: Data, keyPEM: Data, p12: Data) {
        var c: UnsafeMutablePointer<UInt8>?, k: UnsafeMutablePointer<UInt8>?, p: UnsafeMutablePointer<UInt8>?
        var cl = 0, kl = 0, pl = 0
        guard PRGenerateIdentity(p12Password, &c, &cl, &k, &kl, &p, &pl) == 0 else {
            throw PairingCryptoError.failed("generateIdentity")
        }
        return (take(c, cl), takeSecure(k, kl), takeSecure(p, pl))
    }

    static func sign(_ data: Data, keyPEM: Data) throws -> Data {
        var s: UnsafeMutablePointer<UInt8>?; var sl = 0
        let rc = keyPEM.withUnsafeBytes { k in data.withUnsafeBytes { d in
            PRSignSHA256(k.bindMemory(to: UInt8.self).baseAddress, k.count,
                         d.bindMemory(to: UInt8.self).baseAddress, d.count, &s, &sl) } }
        guard rc == 0 else { throw PairingCryptoError.failed("sign") }
        return take(s, sl)
    }

    static func verify(_ data: Data, signature: Data, certPEM: Data) throws -> Bool {
        let rc = certPEM.withUnsafeBytes { c in data.withUnsafeBytes { d in signature.withUnsafeBytes { s in
            PRVerifySHA256(c.bindMemory(to: UInt8.self).baseAddress, c.count,
                           d.bindMemory(to: UInt8.self).baseAddress, d.count,
                           s.bindMemory(to: UInt8.self).baseAddress, s.count) } } }
        guard rc >= 0 else { throw PairingCryptoError.failed("verify") }
        return rc == 1
    }

    static func certificateSignature(certPEM: Data) throws -> Data {
        var s: UnsafeMutablePointer<UInt8>?; var sl = 0
        let rc = certPEM.withUnsafeBytes { PRCertSignature($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &s, &sl) }
        guard rc == 0 else { throw PairingCryptoError.failed("certificateSignature") }
        return take(s, sl)
    }

    static func certificateDER(certPEM: Data) throws -> Data {
        var s: UnsafeMutablePointer<UInt8>?; var sl = 0
        let rc = certPEM.withUnsafeBytes { PRCertDER($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &s, &sl) }
        guard rc == 0 else { throw PairingCryptoError.failed("certificateDER") }
        return take(s, sl)
    }

    static func aes128ECB(encrypt: Bool, key: Data, _ input: Data) throws -> Data {
        guard key.count == 16, input.count % 16 == 0 else { throw PairingCryptoError.failed("aes sizes") }
        var out = Data(count: input.count)
        let rc = out.withUnsafeMutableBytes { o in key.withUnsafeBytes { k in input.withUnsafeBytes { i in
            PRAES128ECB(encrypt ? 1 : 0, k.bindMemory(to: UInt8.self).baseAddress,
                        i.bindMemory(to: UInt8.self).baseAddress, i.count,
                        o.bindMemory(to: UInt8.self).baseAddress) } } }
        guard rc == 0 else { throw PairingCryptoError.failed("aes") }
        return out
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        // RNG failure is unrecoverable; never hand back zeros.
        if status != errSecSuccess { fatalError("SecRandomCopyBytes failed: \(status)") }
        return data
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var bytes = [UInt8](); bytes.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo); i += 2
        }
        self.init(bytes)
    }
}
