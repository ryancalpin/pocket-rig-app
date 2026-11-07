import Foundation
import SwiftData
import Testing
@testable import PocketRig

/// A Helper whose downloads list can be switched off mid-test.
private struct DownloadsRequester: HelperRequesting {
    let up: Flag

    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        switch path {
        case "/v1/info": return (Data(HelperFixtures.readyInfo.utf8), 200)
        case "/v1/downloads" where up.value: return (Data(HelperFixtures.downloads.utf8), 200)
        default: throw HelperError.unreachable
        }
    }
}

/// A Helper whose downloads answer takes a while, so a test can interrupt it.
private struct SlowDownloadsRequester: HelperRequesting {
    var delay: Duration

    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        if path == "/v1/info" { return (Data(HelperFixtures.readyInfo.utf8), 200) }
        try await Task.sleep(for: delay)
        return (Data(HelperFixtures.downloads.utf8), 200)
    }
}

@Suite @MainActor struct DownloadsCardTests {
    private let online = CoverHostStatus.online(runningAppID: 0, runningTitle: nil, apps: [])

    private func info(_ json: String) throws -> HelperStatus { .present(try HelperFixtures.decode(json)) }

    private func pairedHost() throws -> (Host, ModelContext) {
        let container = try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let host = Host(serverUniqueID: "SRV1", name: "Omen", lanAddress: "192.168.1.50", tailscaleAddress: nil)
        host.serverCertPEM = Data("PEM".utf8)
        context.insert(host)
        try context.save()
        return (host, context)
    }

    @Test func stateFollowsThePCThenTheHelperThenSteam() throws {
        let downloads: [HelperDownload] = try HelperFixtures.decode(#"[{"appID":570,"name":"Dota 2","state":"downloading","bytesDownloaded":1,"bytesToDownload":2}]"#)
        func make(_ cover: CoverHostStatus, _ helper: HelperStatus, _ list: [HelperDownload]? = nil, misses: Int = 0) -> DownloadsCardState {
            .make(pcName: "Omen", cover: cover, helper: helper, downloads: list, misses: misses)
        }
        #expect(make(.checking, .unknown) == .checking)
        #expect(make(.offline, try info(HelperFixtures.readyInfo)) == .pcOffline(pc: "Omen"))
        // Sunshine no longer accepting this phone is a pairing matter, not "can't reach".
        #expect(make(.needsPairing, .absent) == .needsPairing(pc: "Omen"))
        #expect(DownloadsCardState.needsPairing(pc: "Omen").headline.contains("Pair"))
        #expect(!DownloadsCardState.needsPairing(pc: "Omen").headline.contains("reach"))
        #expect(DownloadsCardState.make(pcName: "Omen", cover: online, helper: .absent, downloads: nil, misses: 0,
                                        needsRepair: true) == .needsPairing(pc: "Omen"))
        #expect(make(online, .needsAppUpdate) == .needsAppUpdate(pc: "Omen"))
        #expect(DownloadsCardState.needsAppUpdate(pc: "Omen").message == HelperStatus.updateAppNote)
        #expect(make(online, .unknown) == .checking)
        #expect(make(online, .absent) == .noHelper)
        #expect(make(online, try info(HelperFixtures.freshInfo)) == .steamNotSetUp(pc: "Omen"))
        #expect(make(online, try info(#"{"apiVersion":1,"steam":{"state":"notInstalled"}}"#)) == .steamMissing(pc: "Omen"))
        #expect(make(online, try info(HelperFixtures.readyInfo), nil) == .checking)
        // One missed check keeps the last list; two in a row, or no list at all, says "can't check".
        #expect(make(online, try info(HelperFixtures.readyInfo), downloads, misses: 1) == .active(downloads))
        #expect(make(online, try info(HelperFixtures.readyInfo), [], misses: 1) == .idle(pc: "Omen"))
        #expect(make(online, try info(HelperFixtures.readyInfo), downloads, misses: 2) == .unavailable(pc: "Omen"))
        #expect(make(online, try info(HelperFixtures.readyInfo), nil, misses: 1) == .unavailable(pc: "Omen"))
        #expect(make(online, try info(HelperFixtures.readyInfo), []) == .idle(pc: "Omen"))
        #expect(make(online, try info(HelperFixtures.readyInfo), downloads) == .active(downloads))
    }

    @Test func wordsArePlainAndShort() {
        let states: [DownloadsCardState] = [.checking, .pcOffline(pc: "Omen"), .noHelper, .steamMissing(pc: "Omen"),
                                            .steamNotSetUp(pc: "Omen"), .unavailable(pc: "Omen"), .idle(pc: "Omen"), .active([])]
        for state in states {
            #expect(!state.headline.isEmpty)
            let message = state.message ?? ""
            let sentences = message.split(whereSeparator: { ".!?".contains($0) })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count <= 2, "\(message)")
            #expect(!(state.headline + message).localizedCaseInsensitiveContains("error"))
        }
        #expect(DownloadsCardState.steamNotSetUp(pc: "Omen").message?.contains("Omen") == true)
        #expect(DownloadsCardState.active([]).message == nil)
    }

    @Test func downloadsRefreshKeepsTheLastListThroughAMiss() async throws {
        let (host, _) = try pairedHost()
        let up = Flag(true)
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in HelperClient(requester: DownloadsRequester(up: up)) })
        await model.refreshHelper(host, preferredAddress: nil)

        await model.refreshDownloads(host)
        #expect(model.helperDownloads["SRV1"]?.map(\.appID) == [570, 1086940])
        #expect(!model.helperDownloadFailures.contains("SRV1"))

        up.value = false
        await model.refreshDownloads(host)
        #expect(model.helperDownloads["SRV1"]?.count == 2)
        #expect(model.helperDownloadFailures.contains("SRV1"))
        #expect(model.helperDownloadMisses["SRV1"] == 1)
        await model.refreshDownloads(host)
        #expect(model.helperDownloads["SRV1"]?.count == 2)
        #expect(model.helperDownloadMisses["SRV1"] == 2)

        up.value = true
        await model.refreshDownloads(host)
        #expect(!model.helperDownloadFailures.contains("SRV1"))
        #expect(model.helperDownloadMisses["SRV1"] == nil)
    }

    private func slowModel(delay: Duration) throws -> AppModel {
        try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                     makeRequester: { _, _ in StubRequester() },
                     makeHelperClient: { _, _ in HelperClient(requester: SlowDownloadsRequester(delay: delay)) })
    }

    @Test func anOlderDownloadsAnswerIsDroppedAfterTheHelperIsRechecked() async throws {
        let (host, _) = try pairedHost()
        let model = try slowModel(delay: .milliseconds(300))
        await model.refreshHelper(host, preferredAddress: nil)
        let poll = Task { await model.refreshDownloads(host) }
        try await Task.sleep(for: .milliseconds(80))
        await model.refreshHelper(host, preferredAddress: nil)
        await poll.value
        #expect(model.helperDownloads["SRV1"] == nil)
        #expect(model.helperDownloadMisses["SRV1"] == nil)
    }

    @Test func aPCDeletedMidPollStoresNoDownloads() async throws {
        let (host, context) = try pairedHost()
        let model = try slowModel(delay: .milliseconds(300))
        await model.refreshHelper(host, preferredAddress: nil)
        let poll = Task { await model.refreshDownloads(host) }
        try await Task.sleep(for: .milliseconds(80))
        context.delete(host)
        try context.save()
        await poll.value
        #expect(model.helperDownloads["SRV1"] == nil)
        #expect(model.helperDownloadMisses["SRV1"] == nil)
    }

    @Test func aCancelledPollKeepsTheListAndCountsNoMiss() async throws {
        let (host, _) = try pairedHost()
        let up = Flag(true)
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in HelperClient(requester: DownloadsRequester(up: up)) })
        await model.refreshHelper(host, preferredAddress: nil)
        await model.refreshDownloads(host)
        let before = model.helperDownloads["SRV1"]
        #expect(before?.count == 2)

        let slow = try slowModel(delay: .milliseconds(500))
        slow.helperDownloads["SRV1"] = before
        await slow.refreshHelper(host, preferredAddress: nil)
        let poll = Task { await slow.refreshDownloads(host) }
        try await Task.sleep(for: .milliseconds(80))
        poll.cancel()
        await poll.value
        #expect(slow.helperDownloads["SRV1"] == before)
        #expect(slow.helperDownloadMisses["SRV1"] == nil)
        #expect(!slow.helperDownloadFailures.contains("SRV1"))
    }

    @Test func aPCWithoutSteamIsNeverAskedForDownloads() async throws {
        let (host, _) = try pairedHost()
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in
                                     HelperClient(requester: FakeHelperRequester(replies: [
                                         "GET /v1/info": (HelperFixtures.freshInfo, 200),
                                         "GET /v1/downloads": (HelperFixtures.downloads, 200),
                                     ]))
                                 })
        await model.refreshHelper(host, preferredAddress: nil)
        await model.refreshDownloads(host)
        #expect(model.helperDownloads["SRV1"] == nil)
        #expect(!model.helperDownloadFailures.contains("SRV1"))
    }

    @Test func demoDataDecodes() {
        #expect(HelperDemo.info.steam.state == .ready)
        #expect(HelperDemo.games.count == 6)
        #expect(HelperDemo.games.allSatisfy { $0.artURLs.count == 2 })
        #expect(HelperDemo.downloads.map(\.name) == ["Baldur's Gate 3", "Cyberpunk 2077"])
    }
}
