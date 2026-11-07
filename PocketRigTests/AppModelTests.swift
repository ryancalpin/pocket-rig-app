import Foundation
import Testing
import SwiftData
@testable import PocketRig

/// Throws a fixed error for every request (e.g. a TLS pin mismatch).
private final class FailingRequester: HostRequesting, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        throw error
    }
}

/// Answers /serverinfo like a PC would and hands every other request to the fake pairing server.
private final class PairingHostRequester: HostRequesting, @unchecked Sendable {
    let fake: FakePairingServer
    static let info = #"<root status_code="200"><hostname>Omen</hostname><uniqueid>SRV1</uniqueid><LocalIP>192.168.1.20</LocalIP><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>"#
    init(_ fake: FakePairingServer) { self.fake = fake }
    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        if path == "/serverinfo" { return Data(Self.info.utf8) }
        return try await fake.get(path, query: query, secure: secure, timeout: timeout)
    }
}

@Suite @MainActor struct AppModelTests {
    static let serverInfoXML = #"<root status_code="200"><hostname>Omen</hostname><uniqueid>SRV1</uniqueid><LocalIP>192.168.1.20</LocalIP><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>"#
    static let pairedInfoXML = #"<root status_code="200"><hostname>Omen</hostname><uniqueid>SRV1</uniqueid><LocalIP>100.101.102.103</LocalIP><PairStatus>1</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>"#
    static let otherServerXML = #"<root status_code="200"><hostname>Neighbor</hostname><uniqueid>SRV2</uniqueid><LocalIP>192.168.1.20</LocalIP><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>"#
    static let unauthorizedXML = #"<root status_code="401" status_message="The client is not authorized. Certificate verification failed."/>"#

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeIdentity() throws -> ClientIdentity {
        let g = try PairingCrypto.generateIdentity(p12Password: ClientIdentity.p12Password)
        return ClientIdentity(certPEM: g.certPEM, keyPEM: g.keyPEM, p12: g.p12, uniqueID: "U")
    }

    /// A saved, paired host reachable only over Tailscale.
    private func pairedHost(in context: ModelContext) throws -> Host {
        let host = Host(serverUniqueID: "SRV1", name: "Omen", lanAddress: nil, tailscaleAddress: "100.101.102.103")
        host.serverCertPEM = Data("PEM".utf8)
        context.insert(host)
        try context.save()
        return host
    }

    @Test func addHostUpsertsByServerUniqueID() async throws {
        let context = try makeContext()
        let stub = StubRequester()
        stub.responses["/serverinfo"] = Self.serverInfoXML
        let model = AppModel(identity: try makeIdentity(),
                             resolver: HostAddressResolver { _ in true }, makeRequester: { _, _ in stub })
        let first = try await model.addHost(address: "100.101.102.103", context: context)
        let second = try await model.addHost(address: "100.101.102.103", context: context)
        #expect(first.persistentModelID == second.persistentModelID)
        #expect(first.tailscaleAddress == "100.101.102.103")
        #expect(first.lanAddress == "192.168.1.20")
        #expect(try context.fetchCount(FetchDescriptor<Host>()) == 1)
    }

    @Test func connectRejectsADifferentServerAtTheSameAddress() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let stub = StubRequester()
        stub.responses["/serverinfo"] = Self.otherServerXML
        let model = AppModel(identity: try makeIdentity(),
                             resolver: HostAddressResolver { _ in true }, makeRequester: { _, _ in stub })
        await #expect(throws: AppModelError.differentHost) { _ = try await model.connect(host) }
        #expect(host.isPaired, "a stranger answering must not clear our pairing")
        #expect(stub.calls.allSatisfy { !$0.secure }, "never talk HTTPS to the wrong server")
    }

    @Test func connectFallsBackToTheNextAddressWhenTheFirstIsAnotherServer() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        host.lanAddress = "192.168.1.20"
        let wrong = StubRequester()
        wrong.responses["/serverinfo"] = Self.otherServerXML
        let right = StubRequester()
        right.responses["/serverinfo"] = Self.pairedInfoXML
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { address, _ in address == "192.168.1.20" ? wrong : right })
        let connection = try await model.connect(host)
        #expect(connection.address == "100.101.102.103")
        #expect(connection.info.uniqueID == "SRV1")
    }

    @Test func connectTreats401AsNotPairedAndClearsTheCertificate() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let plain = StubRequester()
        plain.responses["/serverinfo"] = Self.serverInfoXML
        let secure = StubRequester()
        secure.responses["/serverinfo"] = Self.unauthorizedXML
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, cert in cert == nil ? plain : secure })
        await #expect(throws: HostError.notPaired) { _ = try await model.connect(host) }
        #expect(!host.isPaired)
    }

    @Test func connectTreatsPinMismatchAsNotPairedAndClearsTheCertificate() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let plain = StubRequester()
        plain.responses["/serverinfo"] = Self.serverInfoXML
        let secure = FailingRequester(HostError.certificatePinMismatch)
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, cert -> HostRequesting in cert == nil ? plain : secure })
        await #expect(throws: HostError.notPaired) { _ = try await model.connect(host) }
        #expect(!host.isPaired)
    }

    @Test func connectThrowsUnreachableWhenNoAddressAnswers() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in false },
                             makeRequester: { _, _ in StubRequester() })
        await #expect(throws: HostError.unreachable) { _ = try await model.connect(host) }
        #expect(host.isPaired)
    }

    @Test func connectSucceedsForAPairedHost() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let stub = StubRequester()
        stub.responses["/serverinfo"] = Self.pairedInfoXML
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, _ in stub })
        let connection = try await model.connect(host)
        #expect(connection.address == "100.101.102.103")
        #expect(connection.info.isPaired)
        #expect(stub.calls.last?.secure == true)
        #expect(host.lastConnectedAt != nil)
    }

    @Test func aStatusProbeLeavesLastConnectedAtAlone() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let stub = StubRequester()
        stub.responses["/serverinfo"] = Self.pairedInfoXML
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, _ in stub })
        let connection = try await model.connect(host, touch: false)
        #expect(connection.info.isPaired)
        #expect(host.lastConnectedAt == nil)
        let before = Date(timeIntervalSince1970: 1_000)
        host.lastConnectedAt = before
        _ = try await model.connect(host, touch: false)
        #expect(host.lastConnectedAt == before)
    }

    /// The cover screen probes every 30 s. A different Sunshine answering at the same address (pin mismatch),
    /// a 401 or PairStatus 0 must show "Needs pairing" without deleting the certificate.
    @Test(arguments: ["pin", "401", "unpaired"])
    func aBackgroundProbeNeverForgetsThePairing(failure: String) async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let plain = StubRequester()
        plain.responses["/serverinfo"] = Self.serverInfoXML
        let secure: HostRequesting
        switch failure {
        case "pin":
            secure = FailingRequester(HostError.certificatePinMismatch)
        case "401":
            let stub = StubRequester()
            stub.responses["/serverinfo"] = Self.unauthorizedXML
            secure = stub
        default:
            let stub = StubRequester()
            stub.responses["/serverinfo"] = Self.serverInfoXML   // PairStatus 0
            secure = stub
        }
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, cert -> HostRequesting in cert == nil ? plain : secure })
        await #expect(throws: HostError.notPaired) {
            _ = try await model.connect(host, touch: false, forgetOnFailure: false)
        }
        #expect(host.isPaired)
        #expect(CoverHostStatus.failed(HostError.notPaired) == .needsPairing)
    }

    @Test func unknownErrorsGetPlainSentences() {
        let odd = PairingCryptoError.failed("keychain -34018")
        #expect(AppModel.message(for: odd) == "Something went wrong. Try again.")
        #expect(AppModel.pairingMessage(for: odd) == "Something went wrong while pairing. Try again.")
        #expect(!AppModel.message(for: odd).contains("-34018"))
    }

    @Test func pairingMessageExplainsAPendingEarlierRequest() {
        let busy = AppModel.pairingMessage(for: HostError.status(409, "A pairing session with this uniqueid already exists"))
        #expect(busy.contains("still waiting for an earlier PIN"))
        #expect(AppModel.pairingMessage(for: PairingError.alreadyInProgress) == busy)
        #expect(AppModel.pairingMessage(for: PairingError.wrongPIN).contains("PIN"))
    }

    // MARK: Hosts

    @Test func addHostKeepsATypedLANAddressAsTheLANAddress() async throws {
        let context = try makeContext()
        let stub = StubRequester()
        stub.responses["/serverinfo"] = Self.serverInfoXML   // reports LocalIP 192.168.1.20
        let model = AppModel(identity: try makeIdentity(),
                             resolver: HostAddressResolver { _ in true }, makeRequester: { _, _ in stub })
        let host = try await model.addHost(address: "  192.168.1.55 ", context: context)
        #expect(host.lanAddress == "192.168.1.55", "the typed address was proven to work, so it wins")
        #expect(host.tailscaleAddress == nil)
    }

    @Test func pairSavesTheServerCertificate() async throws {
        let context = try makeContext()
        let host = Host(serverUniqueID: "SRV1", name: "Omen", lanAddress: "192.168.1.20", tailscaleAddress: nil)
        context.insert(host)
        let fake = FakePairingServer(pin: "4821")
        let requester = PairingHostRequester(fake)
        let model = AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                             makeRequester: { _, _ in requester })
        #expect(!host.isPaired)
        try await model.pair(host, pin: "4821")
        #expect(host.serverCertPEM == fake.server.certPEM)
        #expect(host.isPaired)
    }

    // MARK: Navigation

    private func makeModel() throws -> AppModel {
        AppModel(identity: try makeIdentity(), resolver: HostAddressResolver { _ in true },
                 makeRequester: { _, _ in StubRequester() })
    }

    @Test func replaceTopOnlySwapsWhenTheExpectedRouteIsOnTop() throws {
        let model = try makeModel()
        model.path = [.apps(serverUniqueID: "A"), .stream(serverUniqueID: "A", appID: 1)]
        model.replaceTop(.apps(serverUniqueID: "A"), with: .pair(serverUniqueID: "A"))
        #expect(model.path == [.apps(serverUniqueID: "A"), .stream(serverUniqueID: "A", appID: 1)], "wrong top: no change")
        model.replaceTop(.stream(serverUniqueID: "A", appID: 1), with: .pair(serverUniqueID: "A"))
        #expect(model.path == [.apps(serverUniqueID: "A"), .pair(serverUniqueID: "A")])
        model.path = []
        model.replaceTop(.apps(serverUniqueID: "A"), with: .pair(serverUniqueID: "A"))
        #expect(model.path.isEmpty)
    }

    @Test func finishPairingPopsBackToAnAppListAlreadyBelow() throws {
        let model = try makeModel()
        model.path = [.apps(serverUniqueID: "A"), .pair(serverUniqueID: "A")]
        model.finishPairing(serverUniqueID: "A")
        #expect(model.path == [.apps(serverUniqueID: "A")])
    }

    @Test func finishPairingReplacesALonePairingScreen() throws {
        let model = try makeModel()
        model.path = [.pair(serverUniqueID: "A")]
        model.finishPairing(serverUniqueID: "A")
        #expect(model.path == [.apps(serverUniqueID: "A")])
    }

    @Test func finishPairingIgnoresAScreenThatIsNoLongerOnTop() throws {
        let model = try makeModel()
        model.path = [.pair(serverUniqueID: "A"), .apps(serverUniqueID: "B")]
        model.finishPairing(serverUniqueID: "A")
        #expect(model.path == [.pair(serverUniqueID: "A"), .apps(serverUniqueID: "B")])
    }
}
