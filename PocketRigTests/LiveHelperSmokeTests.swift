import Foundation
import Testing
@testable import PocketRig

/// Opt-in check against the real Helper on the Omen. Needs the pairing `LiveStreamSmokeTests` cached.
/// `TEST_RUNNER_PR_LIVE=1 TEST_RUNNER_PR_LIVE_HOST=<pc address> xcodebuild test ... -only-testing:PocketRigTests/LiveHelperSmokeTests`.
@Suite struct LiveHelperSmokeTests {
    private static var isOn: Bool { ProcessInfo.processInfo.environment["PR_LIVE"] == "1" }

    private func pairedClient(identity: ClientIdentity) throws -> HelperClient {
        let pem = try #require(LiveStreamSmokeTests.store.read("servercert"),
                               "No cached pairing. Run LiveStreamSmokeTests once first.")
        let http = try #require(HelperHTTPClient(address: LiveStreamSmokeTests.address, identity: identity,
                                                 pinnedServerCertDER: try PairingCrypto.certificateDER(certPEM: pem)))
        return HelperClient(requester: http)
    }

    @Test(.enabled(if: isOn), .timeLimit(.minutes(1)))
    func helperAnswersThePairedPhone() async throws {
        let client = try pairedClient(identity: try ClientIdentity.loadOrCreate())
        let info = try await client.info()
        print("LIVE helper: v\(info.version) api=\(info.apiVersion) host=\(info.hostname) steam=\(info.steam.state) caps=\(info.capabilities.map(\.rawValue).sorted()) wake=\(info.wake.map { "\($0.interface) linkUp=\($0.linkUp)" } ?? "none")")
        #expect(info.apiVersion == 1)
        #expect([.notSetUp, .ready].contains(info.steam.state))
        #expect(info.can(.sleep))
        #expect(info.can(.restart))
        #expect(info.can(.lock))
        if info.steam.state != .ready {
            await #expect(throws: HelperError.refused(code: "steam_not_ready", status: 409)) { _ = try await client.library() }
        }
    }

    @Test(.enabled(if: isOn), .timeLimit(.minutes(1)))
    func helperTurnsAwayAPhoneSunshineNeverPaired() async throws {
        let stranger = try HelperFixtures.identity()
        let client = try pairedClient(identity: stranger)
        do {
            _ = try await client.info()
            Issue.record("The Helper answered a phone that was never paired")
        } catch let error as HelperError {
            print("LIVE stranger refused: \(error)")
            #expect(error == .notPaired || error == .unreachable)
        }
    }
}
