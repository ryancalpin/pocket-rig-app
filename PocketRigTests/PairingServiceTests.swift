import Testing
import Foundation
@testable import PocketRig

/// Server side of the GameStream pairing protocol, enough to exercise the client.
final class FakePairingServer: HostRequesting, @unchecked Sendable {
    let pin: String
    let server = try! PairingCrypto.generateIdentity(p12Password: "s")
    var key = Data(), clientCertPEM = Data(), serverChallenge = Data(), serverSecret = Data()
    var clientChallengeResponseHash = Data()
    var pairedOverHTTPS = false
    var unpairCalls = 0
    init(pin: String) { self.pin = pin }

    private func xml(_ body: String) -> Data { Data(#"<root status_code="200">\#(body)</root>"#.utf8) }

    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        let q = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        if q["phrase"] == "getservercert" {
            let salt = Data(hex: q["salt"]!)!
            clientCertPEM = Data(hex: q["clientcert"]!)!
            key = Data(PairingCrypto.sha256(salt + Data(pin.utf8)).prefix(16))
            return xml("<paired>1</paired><plaincert>\(server.certPEM.hexString)</plaincert>")
        }
        if let challenge = q["clientchallenge"] {
            let clientChallenge = try PairingCrypto.aes128ECB(encrypt: false, key: key, Data(hex: challenge)!)
            serverSecret = PairingCrypto.randomBytes(16)
            serverChallenge = PairingCrypto.randomBytes(16)
            let serverCertSig = try PairingCrypto.certificateSignature(certPEM: server.certPEM)
            let hash = PairingCrypto.sha256(clientChallenge + serverCertSig + serverSecret)
            let plain = hash + serverChallenge   // 48 bytes
            let enc = try PairingCrypto.aes128ECB(encrypt: true, key: key, plain)
            return xml("<paired>1</paired><challengeresponse>\(enc.hexString)</challengeresponse>")
        }
        if let resp = q["serverchallengeresp"] {
            clientChallengeResponseHash = try PairingCrypto.aes128ECB(encrypt: false, key: key, Data(hex: resp)!)
            let sig = try PairingCrypto.sign(serverSecret, keyPEM: server.keyPEM)
            return xml("<paired>1</paired><pairingsecret>\((serverSecret + sig).hexString)</pairingsecret>")
        }
        if let secretHex = q["clientpairingsecret"] {
            let blob = Data(hex: secretHex)!
            let clientSecret = Data(blob.prefix(16)), sig = Data(blob.dropFirst(16))
            let clientCertSig = try PairingCrypto.certificateSignature(certPEM: clientCertPEM)
            let expected = PairingCrypto.sha256(serverChallenge + clientCertSig + clientSecret)
            let hashOK = expected == Data(clientChallengeResponseHash.prefix(32))
            let sigOK = try PairingCrypto.verify(clientSecret, signature: sig, certPEM: clientCertPEM)
            let ok = hashOK && sigOK
            return xml("<paired>\(ok ? 1 : 0)</paired>")
        }
        if q["phrase"] == "pairchallenge" {
            pairedOverHTTPS = secure
            return xml("<paired>1</paired>")
        }
        if path == "/unpair" || q["phrase"] == "unpair" { unpairCalls += 1; return xml("") }
        throw HostError.malformed
    }
}

@Suite struct PairingServiceTests {
    let identity = try! { () throws -> ClientIdentity in
        let g = try PairingCrypto.generateIdentity(p12Password: ClientIdentity.p12Password)
        return ClientIdentity(certPEM: g.certPEM, keyPEM: g.keyPEM, p12: g.p12, uniqueID: "0123456789ABCDEF")
    }()

    @Test func pairsWithCorrectPIN() async throws {
        let fake = FakePairingServer(pin: "4821")
        let service = PairingService(requester: fake, identity: identity)
        let serverCert = try await service.pair(pin: "4821") { _ in fake }
        #expect(serverCert == fake.server.certPEM)
        #expect(fake.pairedOverHTTPS)
    }

    @Test func wrongPINFails() async throws {
        let fake = FakePairingServer(pin: "4821")
        let service = PairingService(requester: fake, identity: identity)
        await #expect(throws: PairingError.wrongPIN) {
            _ = try await service.pair(pin: "0000") { _ in fake }
        }
        #expect(fake.unpairCalls == 1)
    }

    @Test func pinIsFourDigits() {
        let pin = PairingService.makePIN()
        #expect(pin.count == 4 && pin.allSatisfy(\.isNumber))
    }
}
