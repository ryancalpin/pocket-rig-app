import Testing
import Foundation
import Security
@testable import PocketRig

struct TLSPinTests {
    private func makeCert() throws -> (der: Data, cert: SecCertificate) {
        let generated = try PairingCrypto.generateIdentity(p12Password: "test")
        let der = try PairingCrypto.certificateDER(certPEM: generated.certPEM)
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        return (der, cert)
    }

    private func trust(for certs: [SecCertificate]) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func matchingCertPasses() throws {
        let a = try makeCert()
        #expect(TLSDelegate.matches(trust: try trust(for: [a.cert]), pinnedDER: a.der))
    }

    @Test func differentCertIsRejected() throws {
        let a = try makeCert(), b = try makeCert()
        #expect(!TLSDelegate.matches(trust: try trust(for: [a.cert]), pinnedDER: b.der))
    }

    @Test func missingPinIsRejected() throws {
        let a = try makeCert()
        #expect(!TLSDelegate.matches(trust: try trust(for: [a.cert]), pinnedDER: nil))
    }

    @Test func emptyChainIsRejected() throws {
        let a = try makeCert()
        var empty: SecTrust?
        let status = SecTrustCreateWithCertificates([] as CFArray, SecPolicyCreateBasicX509(), &empty)
        if status == errSecSuccess, let empty {
            #expect(!TLSDelegate.matches(trust: empty, pinnedDER: a.der))
        } else {
            // The system refuses to build a trust with no certificates, so there is nothing to match.
            #expect(empty == nil)
        }
    }
}
