import Foundation

enum PairingError: Error, Equatable {
    case wrongPIN
    case alreadyInProgress
    case serverRejected(String)
    case certificateMismatch
}

/// Client side of the GameStream/Sunshine PIN pairing handshake.
struct PairingService: Sendable {
    private let requester: HostRequesting
    private let identity: ClientIdentity
    private let deviceName: String

    init(requester: HostRequesting, identity: ClientIdentity, deviceName: String = "Pocket Rig") {
        self.requester = requester
        self.identity = identity
        self.deviceName = deviceName
    }

    /// Returns the server certificate PEM to pin. `secureRequester` is built by the caller from that cert
    /// for the final HTTPS step.
    func pair(pin: String, secureRequester: @Sendable (Data) -> HostRequesting) async throws -> Data {
        // Step 1 is the only step that can fail without a half-created pairing on the host.
        let salt = PairingCrypto.randomBytes(16)
        let first = try await step(requester, secure: false, timeout: 120, [
            ("phrase", "getservercert"),
            ("salt", salt.hexString),
            ("clientcert", identity.certPEM.hexString),
        ])
        guard first["paired"] == "1" else { throw PairingError.serverRejected("getservercert") }
        guard let certHex = first["plaincert"], !certHex.isEmpty, let serverCertPEM = Data(hex: certHex) else {
            throw PairingError.alreadyInProgress
        }

        do {
            return try await finish(pin: pin, salt: salt, serverCertPEM: serverCertPEM,
                                    secureRequester: secureRequester)
        } catch {
            // Best-effort cleanup; never mask the original error.
            _ = try? await requester.get("/unpair", query: [
                URLQueryItem(name: "devicename", value: deviceName),
                URLQueryItem(name: "updateState", value: "1"),
            ], secure: false, timeout: 10)
            throw error
        }
    }

    private func finish(pin: String, salt: Data, serverCertPEM: Data,
                        secureRequester: @Sendable (Data) -> HostRequesting) async throws -> Data {
        // Step 2: client challenge.
        let aesKey = Data(PairingCrypto.sha256(salt + Data(pin.utf8)).prefix(16))
        let clientChallenge = PairingCrypto.randomBytes(16)
        let encChallenge = try PairingCrypto.aes128ECB(encrypt: true, key: aesKey, clientChallenge)
        let second = try await step(requester, secure: false, timeout: 30, [
            ("clientchallenge", encChallenge.hexString),
        ])
        guard second["paired"] == "1" else { throw PairingError.serverRejected("clientchallenge") }
        guard let respHex = second["challengeresponse"], let respEnc = Data(hex: respHex), respEnc.count >= 48
        else { throw HostError.malformed }
        let resp = try PairingCrypto.aes128ECB(encrypt: false, key: aesKey, respEnc)
        guard resp.count >= 48 else { throw HostError.malformed }
        let serverResponse = Data(resp.prefix(32))
        let serverChallenge = Data(resp[resp.startIndex + 32 ..< resp.startIndex + 48])

        // Step 3: server challenge response.
        let clientSecret = PairingCrypto.randomBytes(16)
        let clientCertSig = try PairingCrypto.certificateSignature(certPEM: identity.certPEM)
        let hash = PairingCrypto.sha256(serverChallenge + clientCertSig + clientSecret)
        let encHash = try PairingCrypto.aes128ECB(encrypt: true, key: aesKey, hash)
        let third = try await step(requester, secure: false, timeout: 30, [
            ("serverchallengeresp", encHash.hexString),
        ])
        guard third["paired"] == "1" else { throw PairingError.wrongPIN }
        guard let secretHex = third["pairingsecret"], let secretBlob = Data(hex: secretHex), secretBlob.count > 16
        else { throw HostError.malformed }
        let serverSecret = Data(secretBlob.prefix(16))
        let serverSig = Data(secretBlob.dropFirst(16))

        // Step 4: verify the server, then prove ourselves.
        guard try PairingCrypto.verify(serverSecret, signature: serverSig, certPEM: serverCertPEM) else {
            throw PairingError.certificateMismatch
        }
        let serverCertSig = try PairingCrypto.certificateSignature(certPEM: serverCertPEM)
        let expected = PairingCrypto.sha256(clientChallenge + serverCertSig + serverSecret)
        guard expected == serverResponse else { throw PairingError.wrongPIN }
        let mySig = try PairingCrypto.sign(clientSecret, keyPEM: identity.keyPEM)
        let fourth = try await step(requester, secure: false, timeout: 30, [
            ("clientpairingsecret", (clientSecret + mySig).hexString),
        ])
        guard fourth["paired"] == "1" else { throw PairingError.wrongPIN }

        // Step 5: confirm over HTTPS pinned to the server cert.
        let fifth = try await step(secureRequester(serverCertPEM), secure: true, timeout: 30, [
            ("phrase", "pairchallenge"),
        ])
        guard fifth["paired"] == "1" else { throw PairingError.serverRejected("pairchallenge") }
        return serverCertPEM
    }

    private func step(_ requester: HostRequesting, secure: Bool, timeout: TimeInterval,
                      _ items: [(String, String)]) async throws -> [String: String] {
        var query = [URLQueryItem(name: "devicename", value: deviceName),
                     URLQueryItem(name: "updateState", value: "1")]
        query += items.map { URLQueryItem(name: $0.0, value: $0.1) }
        let data = try await requester.get("/pair", query: query, secure: secure, timeout: timeout)
        return try NvXML.parse(data).requireOK().values
    }

    /// Four random digits (0000-9999).
    static func makePIN() -> String {
        var rng = SystemRandomNumberGenerator()
        return String(format: "%04d", Int.random(in: 0...9999, using: &rng))
    }
}
