import Testing
import Foundation
import Security
@testable import PocketRig

@Suite struct PairingCryptoTests {
    @Test func aesECBMatchesNISTVector() throws {
        // NIST SP 800-38A F.1.1
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
        let plain = Data(hex: "6bc1bee22e409f96e93d7e117393172a")!
        let cipher = try PairingCrypto.aes128ECB(encrypt: true, key: key, plain)
        #expect(cipher.hexString == "3ad77bb40d7a3660a89ecaf32466ef97")
        #expect(try PairingCrypto.aes128ECB(encrypt: false, key: key, cipher) == plain)
    }

    @Test func signAndVerifyRoundTrip() throws {
        let id = try PairingCrypto.generateIdentity(p12Password: "t")
        let message = Data("hello".utf8)
        let sig = try PairingCrypto.sign(message, keyPEM: id.keyPEM)
        #expect(sig.count == 256) // RSA-2048
        #expect(try PairingCrypto.verify(message, signature: sig, certPEM: id.certPEM))
        #expect(try !PairingCrypto.verify(Data("tampered".utf8), signature: sig, certPEM: id.certPEM))
    }

    @Test func certificateFieldsAreReadable() throws {
        let id = try PairingCrypto.generateIdentity(p12Password: "t")
        #expect(String(decoding: id.certPEM, as: UTF8.self).hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(try PairingCrypto.certificateSignature(certPEM: id.certPEM).count == 256)
        #expect(try PairingCrypto.certificateDER(certPEM: id.certPEM).first == 0x30)
    }

    @Test func hexRoundTrip() {
        #expect(Data(hex: "00ff10")!.hexString == "00ff10")
        #expect(Data(hex: "zz") == nil)
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "+1") == nil)
        #expect(Data(hex: "-1") == nil)
        #expect(Data(hex: "ABcd")!.hexString == "abcd")
    }

    @Test func aesECBTwoBlocksAndMisalignedLength() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
        let plain = Data(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")!
        let cipher = try PairingCrypto.aes128ECB(encrypt: true, key: key, plain)
        #expect(cipher.hexString == "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf")
        #expect(try PairingCrypto.aes128ECB(encrypt: false, key: key, cipher) == plain)
        #expect(throws: PairingCryptoError.self) {
            try PairingCrypto.aes128ECB(encrypt: true, key: key, Data(count: 17))
        }
    }

    @Test func randomBytesBehaves() {
        let a = PairingCrypto.randomBytes(32), b = PairingCrypto.randomBytes(32)
        #expect(a.count == 32)
        #expect(a != Data(count: 32))
        #expect(a != b)
        #expect(PairingCrypto.randomBytes(0).isEmpty)
    }

    @Test func signatureVerifiesWithAppleSecurity() throws {
        let id = try PairingCrypto.generateIdentity(p12Password: "t")
        let message = Data("apple verifies".utf8)
        let sig = try PairingCrypto.sign(message, keyPEM: id.keyPEM)
        let der = try PairingCrypto.certificateDER(certPEM: id.certPEM)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let key = try #require(SecCertificateCopyKey(cert))
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                       message as CFData, sig as CFData, &error)
        #expect(ok)
    }
}
