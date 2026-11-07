import AVFoundation
import Testing
import Foundation
@testable import PocketRig

/// Opt-in end-to-end check against the real Sunshine host. Run with
/// `TEST_RUNNER_PR_LIVE=1 TEST_RUNNER_PR_LIVE_HOST=<pc address> xcodebuild test ... -only-testing:PocketRigTests/LiveStreamSmokeTests`.
/// First run pairs with PIN 1234: start `(sleep 25; scripts/sunshine-pin.sh 1234) &` just before it.
@Suite struct LiveStreamSmokeTests {
    /// The PC to test against, from `TEST_RUNNER_PR_LIVE_HOST` (kept out of the source).
    static let address = ProcessInfo.processInfo.environment["PR_LIVE_HOST"] ?? ""
    static let store = KeychainStore(service: "com.ryancalpin.pocketrig.tests.live")

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PR_LIVE"] == "1"), .timeLimit(.minutes(4)))
    func streamsDesktopVideo() async throws {
        let identity = try ClientIdentity.loadOrCreate()
        let api = try await pairedAPI(identity: identity)

        let info = try await api.serverInfo(secure: true)
        #expect(info.isPaired)
        let apps = try await api.appList()
        let desktop = try #require(apps.first { $0.title == "Desktop" }, "apps: \(apps.map(\.title))")
        print("LIVE serverinfo: app=\(info.appVersion) gfe=\(info.gfeVersion) codecs=\(info.codecModeSupport) current=\(info.currentGameID)")

        var settings = StreamSettings.default
        settings.width = 1280
        settings.height = 720
        settings.fps = 60
        let session = StreamSession(api: api, serverInfo: info, address: Self.address, appID: desktop.id,
                                    settings: settings)
        await session.start()
        print("LIVE after start(): \(session.state)")

        let deadline = ContinuousClock.now + .seconds(20)
        var lastState = session.state
        while ContinuousClock.now < deadline {
            if session.state != lastState { lastState = session.state; print("LIVE state: \(lastState)") }
            if session.state == .streaming { break }
            if case .failed = session.state { break }
            if session.state == .ended { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.state == .streaming, "state: \(session.state)")

        if session.state == .streaming {
            try await Task.sleep(for: .seconds(5))
        }
        print("LIVE frames=\(session.framesSubmitted) idr=\(session.idrFramesSubmitted) rejected=\(session.framesRejected) state=\(session.state)")
        #expect(session.idrFramesSubmitted >= 1)
        #expect(session.framesSubmitted >= 1)

        await session.stop()
        #expect(session.state == .ended)
    }

    /// Instant replay against the real PC: 35 seconds of Desktop, then the clip written to a movie.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PR_LIVE"] == "1"), .timeLimit(.minutes(4)))
    func recordsAReplayClip() async throws {
        let identity = try ClientIdentity.loadOrCreate()
        let api = try await pairedAPI(identity: identity)
        let info = try await api.serverInfo(secure: true)
        let apps = try await api.appList()
        let desktop = try #require(apps.first { $0.title == "Desktop" }, "apps: \(apps.map(\.title))")
        var settings = StreamSettings.default
        settings.width = 1280
        settings.height = 720
        settings.fps = 60
        let session = StreamSession(api: api, serverInfo: info, address: Self.address, appID: desktop.id,
                                    settings: settings)
        await session.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, session.state != .streaming {
            if case .failed = session.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.state == .streaming, "state: \(session.state)")
        try await Task.sleep(for: .seconds(35))
        let replay = session.video.replay
        print("LIVE replay: keyframes=\(replay.keyframeCount) frames=\(replay.frameCount) bytes=\(replay.byteCount) span=\(replay.availableUs / 1000) ms")
        let clip = try #require(replay.clip())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-replay-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ReplayWriter.write(clip, to: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        print("LIVE replay movie: \(duration) s")
        #expect(replay.keyframeCount >= 2)
        #expect(duration >= 20)
        await session.stop()
    }

    /// Reuses a cached server cert when the host still recognizes us; otherwise pairs with PIN 1234.
    private func pairedAPI(identity: ClientIdentity) async throws -> HostAPI {
        if let pem = Self.store.read("servercert") {
            let client = HostHTTPClient(address: Self.address, identity: identity,
                                        pinnedServerCertDER: try PairingCrypto.certificateDER(certPEM: pem))
            let api = HostAPI(requester: client, uniqueID: identity.uniqueID)
            if let info = try? await api.serverInfo(secure: true), info.isPaired {
                print("LIVE using cached pairing")
                return api
            }
            Self.store.delete("servercert")
        }
        print("LIVE pairing with PIN 1234")
        let address = Self.address
        let plain = HostHTTPClient(address: address, identity: identity, pinnedServerCertDER: nil)
        let pem = try await PairingService(requester: plain, identity: identity).pair(pin: "1234") { certPEM in
            HostHTTPClient(address: address, identity: identity,
                           pinnedServerCertDER: try! PairingCrypto.certificateDER(certPEM: certPEM))
        }
        try Self.store.write(pem, account: "servercert")
        let client = HostHTTPClient(address: address, identity: identity,
                                    pinnedServerCertDER: try PairingCrypto.certificateDER(certPEM: pem))
        return HostAPI(requester: client, uniqueID: identity.uniqueID)
    }
}
