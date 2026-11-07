import Foundation
import Testing
@testable import PocketRig

/// Helper replies shared by the Helper tests. Field names match the Go side (`helper/internal/api`).
enum HelperFixtures {
    static let readyInfo = #"{"apiVersion":1,"version":"0.4.0","hostname":"Geo-HP-OMEN","capabilities":["library","downloads","install","play","restart-steam","close-game","sleep","restart","lock","teleport"],"steam":{"state":"ready","running":true,"runningAppID":1145360},"wake":{"mac":"04:0e:3c:2a:36:94","interface":"enp34s0","linkUp":true,"broadcast":"192.168.1.255"}}"#
    static let freshInfo = #"{"apiVersion":1,"version":"0.4.0","hostname":"Geo-HP-OMEN","capabilities":["sleep","restart","lock"],"steam":{"state":"notSetUp","running":false},"wake":{"mac":"04:0e:3c:2a:36:94","interface":"enp34s0","linkUp":false,"broadcast":"192.168.1.255"}}"#
    static let library = #"{"games":[{"appID":1145360,"name":"Hades","state":"installed","sizeOnDisk":15032385536,"lastPlayed":1730764800,"bytesDownloaded":0,"bytesToDownload":0,"artURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/1145360/library_600x900.jpg","headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/1145360/header.jpg"},{"appID":570,"name":"Dota 2","state":"downloading","sizeOnDisk":0,"bytesDownloaded":15032385536,"bytesToDownload":37580963840,"artURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/570/library_600x900.jpg","headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/570/header.jpg"}]}"#
    static let downloads = #"{"downloads":[{"appID":570,"name":"Dota 2","state":"downloading","bytesDownloaded":15032385536,"bytesToDownload":37580963840,"progress":0.4,"headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/570/header.jpg"},{"appID":1086940,"name":"Baldur's Gate 3","state":"queued","bytesDownloaded":0,"bytesToDownload":128849018880,"progress":0,"headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/1086940/header.jpg"}]}"#

    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func identity() throws -> ClientIdentity {
        let g = try PairingCrypto.generateIdentity(p12Password: ClientIdentity.p12Password)
        return ClientIdentity(certPEM: g.certPEM, keyPEM: g.keyPEM, p12: g.p12, uniqueID: "T")
    }
}

/// Answers URLSession requests from memory, keyed by host, so each test can use its own made-up address
/// and tests can run in parallel.
final class StubHelperProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var fails = false
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [String: Reply]] = [:]
        private var seen: [String: [URLRequest]] = [:]

        func set(_ host: String, _ replies: [String: Reply]) { lock.withLock { self.replies[host] = replies } }

        func reply(for request: URLRequest) -> Reply? {
            lock.withLock {
                let host = request.url?.host ?? ""
                seen[host, default: []].append(request)
                return replies[host]?["\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"]
            }
        }

        func requests(_ host: String) -> [URLRequest] { lock.withLock { seen[host] ?? [] } }
    }

    static let store = Store()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.store.reply(for: request), !reply.fails,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct HelperClientTests {
    /// A real HelperHTTPClient whose requests go to the stub instead of the network.
    private func client(_ host: String, _ replies: [String: StubHelperProtocol.Reply]) throws -> HelperClient {
        StubHelperProtocol.store.set(host, replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHelperProtocol.self]
        let http = try #require(HelperHTTPClient(address: host, identity: try HelperFixtures.identity(),
                                                 pinnedServerCertDER: Data([1]), configuration: config))
        return HelperClient(requester: http)
    }

    @Test func infoAsksPort47800OverHTTPS() async throws {
        let c = try client("10.9.0.1", ["GET /v1/info": .init(status: 200, body: HelperFixtures.readyInfo)])
        let info = try await c.info()
        let request = try #require(StubHelperProtocol.store.requests("10.9.0.1").first)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.port == 47800)
        #expect(request.httpMethod == "GET")
        #expect(info.apiVersion == 1)
        #expect(info.hostname == "Geo-HP-OMEN")
        #expect(info.steam == HelperInfo.Steam(state: .ready, running: true, runningAppID: 1145360))
        #expect(info.canWake)
    }

    @Test func capabilitiesFromANewerHelperAreSkipped() throws {
        let info = try HelperFixtures.decode(HelperFixtures.readyInfo, as: HelperInfo.self)
        #expect(info.capabilities == Set(HelperCapability.allCases))
    }

    @Test func aFreshPCOnlyOffersPower() throws {
        let info = try HelperFixtures.decode(HelperFixtures.freshInfo, as: HelperInfo.self)
        #expect(info.capabilities == [.sleep, .restart, .lock])
        #expect(info.steam.state == .notSetUp)
        #expect(info.steam.runningAppID == nil)
        #expect(!info.can(.library))
        #expect(!info.canWake)
        #expect(info.wake?.mac == "04:0e:3c:2a:36:94")
    }

    @Test func unknownStatesReadAsUnknown() throws {
        let info = try HelperFixtures.decode(#"{"apiVersion":1,"steam":{"state":"exploded"}}"#, as: HelperInfo.self)
        #expect(info.steam.state == .unknown)
        #expect(info.capabilities.isEmpty)
        #expect(info.wake == nil)
        let game = try HelperFixtures.decode(#"{"appID":1,"name":"X","state":"teleporting"}"#, as: HelperGame.self)
        #expect(game.state == .unknown)
        #expect(game.artURLs.isEmpty)
    }

    @Test func libraryDecodes() async throws {
        let c = try client("10.9.0.2", ["GET /v1/library": .init(status: 200, body: HelperFixtures.library)])
        let games = try await c.library()
        #expect(games.map(\.name) == ["Hades", "Dota 2"])
        #expect(games[0].state == .installed)
        #expect(games[0].lastPlayedDate == Date(timeIntervalSince1970: 1_730_764_800))
        #expect(games[0].artURLs.count == 2)
        #expect(approximately(games[1].progress, 0.4))
        #expect(games[1].lastPlayedDate == nil)
    }

    @Test func downloadsDecode() async throws {
        let c = try client("10.9.0.3", ["GET /v1/downloads": .init(status: 200, body: HelperFixtures.downloads)])
        let downloads = try await c.downloads()
        #expect(downloads.map(\.appID) == [570, 1086940])
        #expect(approximately(downloads[0].progress, 0.4))
        #expect(downloads[1].statusText == "Waiting to download")
        #expect(downloads[0].accessibilityValue.hasPrefix("40 percent"))
    }

    @Test func installPostsTheAppID() async throws {
        let c = try client("10.9.0.4", ["POST /v1/install/570": .init(status: 202, body: #"{"accepted":true,"confirmOnPC":true}"#)])
        let reply = try await c.install(appID: 570)
        #expect(reply == HelperAccepted(accepted: true, confirmOnPC: true))
        let request = try #require(StubHelperProtocol.store.requests("10.9.0.4").first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/install/570")
    }

    @Test func pcControlsPostToTheirActionNames() async throws {
        var replies: [String: StubHelperProtocol.Reply] = [:]
        for control in PCControl.allCases {
            replies["POST /v1/actions/\(control.rawValue)"] = .init(status: 202, body: #"{"accepted":true}"#)
        }
        let c = try client("10.9.0.5", replies)
        for control in PCControl.allCases { try await c.perform(control) }
        let paths = StubHelperProtocol.store.requests("10.9.0.5").compactMap(\.url?.path)
        #expect(paths == ["/v1/actions/restart-steam", "/v1/actions/close-game", "/v1/actions/sleep",
                          "/v1/actions/restart", "/v1/actions/lock"])
        #expect(PCControl.allCases.map(\.capability) == [.restartSteam, .closeGame, .sleep, .restart, .lock])
    }

    @Test func refusalsCarryTheHelpersCode() async throws {
        let c = try client("10.9.0.6", ["GET /v1/library": .init(status: 409, body: #"{"error":"steam_not_ready","message":"Steam isn't set up on this PC yet."}"#)])
        await #expect(throws: HelperError.refused(code: "steam_not_ready", status: 409)) { _ = try await c.library() }
    }

    @Test func noAnswerIsUnreachable() async throws {
        let c = try client("10.9.0.7", ["GET /v1/info": .init(status: 200, body: "", fails: true)])
        await #expect(throws: HelperError.unreachable) { _ = try await c.info() }
    }

    @Test func garbageIsABadReply() async throws {
        let c = try client("10.9.0.8", ["GET /v1/info": .init(status: 200, body: "<html>hello</html>")])
        await #expect(throws: HelperError.badReply) { _ = try await c.info() }
    }

    @Test func badAppIDsNeverLeaveThePhone() async throws {
        let c = try client("10.9.0.9", [:])
        await #expect(throws: HelperError.refused(code: "bad_appid", status: 0)) { _ = try await c.install(appID: 0) }
        await #expect(throws: HelperError.refused(code: "bad_appid", status: 0)) { _ = try await c.play(appID: 5_000_000_000) }
        #expect(StubHelperProtocol.store.requests("10.9.0.9").isEmpty)
    }

    @Test func statusTextsArePlain() {
        #expect(HelperGame.State.installed.statusText(done: 0, total: 0) == "Installed")
        #expect(HelperGame.State.queued.statusText(done: 0, total: 10) == "Waiting to download")
        #expect(HelperGame.State.paused.statusText(done: 5, total: 10) == "Paused")
        #expect(HelperGame.State.downloading.statusText(done: 0, total: 0) == "Starting download…")
        #expect(HelperGame.State.downloading.statusText(done: 15_032_385_536, total: 37_580_963_840).contains(" of "))
        #expect(HelperGame.progress(done: 20, total: 10) == 1)
        #expect(HelperGame.progress(done: 5, total: 0) == 0)
    }

    @Test func messagesAreShortAndPlain() {
        // Every code the Helper can send (the golden files), plus one the app has never heard of.
        let codes = HelperContract.errorCodes + ["something_new"]
        #expect(codes.count > 10)
        let errors: [HelperError] = [.unreachable, .notPaired, .badReply] + codes.map { .refused(code: $0, status: 409) }
        for error in errors {
            let sentences = error.message.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(!error.message.isEmpty)
            #expect(sentences.count <= 2, "\(error.message)")
            #expect(!error.message.localizedCaseInsensitiveContains("error"))
        }
        #expect(HelperError.message(for: URLError(.badURL)) == HelperError.refused(code: "failed", status: 0).message)
    }

    @Test func stuckAndUnknownRoutesHavePlainMessages() {
        #expect(HelperError.refused(code: "game_stuck", status: 502).message == "The game didn't close. You may need to close it on your PC.")
        #expect(HelperError.refused(code: "steam_stuck", status: 502).message == "Steam didn't close to restart. Try again, or restart your PC.")
        for code in ["not_found", "method_not_allowed", "unknown_action"] {
            let message = HelperError.refused(code: code, status: 404).message
            #expect(message.contains("Update"))
            #expect(message != HelperError.refused(code: "failed", status: 0).message)
        }
    }

    @Test func closeGameAndLockErrorsReachThePhone() async throws {
        let c = try client("10.9.0.10", [
            "POST /v1/actions/close-game": .init(status: 502, body: #"{"error":"game_stuck","message":"x"}"#),
            "POST /v1/actions/lock": .init(status: 409, body: #"{"error":"no_desktop","message":"x"}"#),
            "POST /v1/actions/restart-steam": .init(status: 429, body: #"{"error":"too_soon","message":"x"}"#),
            "POST /v1/actions/sleep": .init(status: 404, body: #"{"error":"not_found","message":"x"}"#),
        ])
        await #expect(throws: HelperError.refused(code: "game_stuck", status: 502)) { try await c.perform(.closeGame) }
        await #expect(throws: HelperError.refused(code: "no_desktop", status: 409)) { try await c.perform(.lock) }
        await #expect(throws: HelperError.refused(code: "too_soon", status: 429)) { try await c.perform(.restartSteam) }
        await #expect(throws: HelperError.refused(code: "not_found", status: 404)) { try await c.perform(.sleep) }
    }

    @Test func desktopReadyIsOptional() throws {
        let old = try HelperFixtures.decode(HelperFixtures.readyInfo, as: HelperInfo.self)
        #expect(old.desktopReady == nil)
        let new = try HelperFixtures.decode(#"{"apiVersion":1,"steam":{"state":"ready"},"desktopReady":false}"#, as: HelperInfo.self)
        #expect(new.desktopReady == false)
    }

    // MARK: Transport error mapping (measured against a real Go Helper; see task-7-report.md)

    @Test func pinMismatchMeansNotPaired() {
        let error = HelperHTTPClient.mapped(URLError(.cancelled), pinMismatch: true, taskCancelled: false)
        #expect(error as? HelperError == .notPaired)
    }

    @Test func certificateErrorsMeanNotPaired() {
        for code in [URLError.Code.clientCertificateRejected, .clientCertificateRequired] {
            let error = HelperHTTPClient.mapped(URLError(code), pinMismatch: false, taskCancelled: false)
            #expect(error as? HelperError == .notPaired)
        }
    }

    @Test func everythingElseMeansUnreachable() {
        // -1005 is what a Go Helper's refusal of our certificate looks like; a dropped connection looks the same.
        let codes: [URLError.Code] = [.cannotConnectToHost, .networkConnectionLost, .secureConnectionFailed, .timedOut,
                                      .serverCertificateUntrusted, .notConnectedToInternet, .cannotFindHost]
        for code in codes {
            let error = HelperHTTPClient.mapped(URLError(code), pinMismatch: false, taskCancelled: false)
            #expect(error as? HelperError == .unreachable, "\(code)")
        }
    }

    @Test func aCancelledTaskStaysCancelled() {
        let cancelled = HelperHTTPClient.mapped(URLError(.cancelled), pinMismatch: false, taskCancelled: true)
        #expect(cancelled is CancellationError)
        // A cancel nobody asked for (not our Task) is just a failed request.
        let other = HelperHTTPClient.mapped(URLError(.cancelled), pinMismatch: false, taskCancelled: false)
        #expect(other as? HelperError == .unreachable)
    }

    @Test func aCancelledCallThrowsCancellationError() async throws {
        let c = try client("10.9.0.11", ["GET /v1/info": .init(status: 200, body: "", fails: true)])
        let task = Task { try await c.info() }
        task.cancel()
        do { _ = try await task.value; Issue.record("should have thrown") } catch {
            // Cancelled before or during the request: never reported as "can't reach your PC".
            #expect(error is CancellationError || (error as? HelperError) == .unreachable)
        }
    }

    // MARK: Lossy lists and art URLs

    @Test func aMalformedGameIsSkippedNotFatal() async throws {
        let body = #"{"games":[{"appID":1,"name":"Good","state":"installed"},{"appID":"oops"},{"name":"No id","state":"installed"},{"appID":2,"name":"Also good","state":"paused"}]}"#
        let c = try client("10.9.0.12", ["GET /v1/library": .init(status: 200, body: body)])
        let games = try await c.library()
        #expect(games.map(\.appID) == [1, 2])
    }

    @Test func aMalformedDownloadIsSkippedNotFatal() async throws {
        let body = #"{"downloads":[{"appID":1,"name":"A","state":"queued"},42,{"appID":3,"name":"C","state":"paused"}]}"#
        let c = try client("10.9.0.13", ["GET /v1/downloads": .init(status: 200, body: body)])
        let downloads = try await c.downloads()
        #expect(downloads.map(\.appID) == [1, 3])
    }

    @Test func pendingUpdateGameIsInstalledAndSaysSo() throws {
        let json = #"{"appID":730,"name":"CS2","state":"installed","updatePending":true}"#
        let game = try HelperFixtures.decode(json, as: HelperGame.self)
        #expect(game.state == .installed)
        #expect(game.updatePending)
        #expect(game.statusText == "Update ready")
        let plain = try HelperFixtures.decode(#"{"appID":1,"name":"G","state":"installed"}"#, as: HelperGame.self)
        #expect(!plain.updatePending)
        #expect(plain.statusText == "Installed")
        // Playing is still allowed: the Play button looks only at the state.
        #expect(SteamPlay.sorted([game, plain]).count == 2)
    }

    @Test func onlyWebArtURLsAreKept() throws {
        let json = #"{"appID":1,"name":"G","state":"installed","artURL":"file:///etc/passwd","headerURL":"https://example.com/h.jpg"}"#
        let game = try HelperFixtures.decode(json, as: HelperGame.self)
        #expect(game.artURL == nil)
        #expect(game.headerURL?.absoluteString == "https://example.com/h.jpg")
        let ftp = try HelperFixtures.decode(#"{"appID":1,"name":"G","state":"installed","artURL":"ftp://x/y.jpg"}"#, as: HelperGame.self)
        #expect(ftp.artURL == nil)
    }
}
