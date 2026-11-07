import Foundation
import SwiftData
import Testing
@testable import PocketRig

@Suite @MainActor struct ShortcutsTests {
    private func makeStore() -> SharedStore {
        SharedStore(defaults: UserDefaults(suiteName: "pocketrig-tests-\(UUID().uuidString)")!)
    }

    private func makeModel(_ store: SharedStore) throws -> AppModel {
        let model = try AppModel(identity: HelperFixtures.identity(), makeRequester: { _, _ in StubRequester() })
        model.sharedStore = store
        return model
    }

    /// Keep the context in a local for the whole test: the hosts live in it.
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func makeHost(_ id: String = "SRV1", name: String = "Omen", in context: ModelContext) throws -> Host {
        let host = Host(serverUniqueID: id, name: name, lanAddress: "192.168.1.50", tailscaleAddress: nil)
        host.serverCertPEM = Data("PEM".utf8)
        context.insert(host)
        try context.save()
        return host
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Storage

    @Test func theStoreKeepsTheLastGameAndThePC() {
        let store = makeStore()
        #expect(store.lastPlayed == nil)
        let last = LastPlayed(serverUniqueID: "SRV1", pcName: "Omen", appID: 7, appTitle: "Desktop",
                              steamGameName: "Baldur's Gate 3", playedAt: t0)
        store.lastPlayed = last
        #expect(store.lastPlayed == last)
        #expect(last.title == "Baldur's Gate 3")
        let pc = PCSnapshot(serverUniqueID: "SRV1", pcName: "Omen", state: .online, runningTitle: "Desktop", checkedAt: t0)
        store.pc = pc
        #expect(store.pc == pc)
        store.pc = nil
        #expect(store.pc == nil)
    }

    @Test func aResumeRequestIsTakenOnceAndOnlyWhileFresh() {
        let store = makeStore()
        #expect(!store.takeResumeRequest(now: t0))
        store.requestResume(at: t0)
        #expect(store.takeResumeRequest(now: t0.addingTimeInterval(5)))
        #expect(!store.takeResumeRequest(now: t0.addingTimeInterval(6)))   // taken
        store.requestResume(at: t0)
        #expect(!store.takeResumeRequest(now: t0.addingTimeInterval(PocketRigShared.resumeRequestLifetime + 1)))
    }

    @Test func pcStatusWordsAreShort() {
        func snap(_ state: PCSnapshot.State, _ title: String? = nil) -> PCSnapshot {
            PCSnapshot(serverUniqueID: "S", pcName: "Omen", state: state, runningTitle: title, checkedAt: t0)
        }
        #expect(snap(.online).statusText == "Online")
        #expect(snap(.online, "Hades II").statusText == "Playing Hades II")
        #expect(snap(.offline).statusText == "Offline")
        #expect(snap(.needsPairing).statusText == "Needs pairing")
        #expect(snap(.online).sameStatus(as: PCSnapshot(serverUniqueID: "S", pcName: "Omen", state: .online,
                                                         runningTitle: nil, checkedAt: t0.addingTimeInterval(99))))
        #expect(!snap(.online).sameStatus(as: snap(.offline)))
    }

    @Test func aSnapshotComesFromTheCoverStatus() {
        let playing = PCSnapshot(serverUniqueID: "S", pcName: "Omen",
                                 status: .online(runningAppID: 3, runningTitle: "Hades II", apps: []), checkedAt: t0)
        #expect(playing?.state == .online)
        #expect(playing?.runningTitle == "Hades II")
        let idle = PCSnapshot(serverUniqueID: "S", pcName: "Omen",
                              status: .online(runningAppID: 0, runningTitle: nil, apps: []), checkedAt: t0)
        #expect(idle?.runningTitle == nil)
        #expect(PCSnapshot(serverUniqueID: "S", pcName: "Omen", status: .offline, checkedAt: t0)?.state == .offline)
        #expect(PCSnapshot(serverUniqueID: "S", pcName: "Omen", status: .checking, checkedAt: t0) == nil)
    }

    // MARK: Where a resume goes

    @Test func planCases() {
        let last = LastPlayed(serverUniqueID: "SRV1", pcName: "Omen", appID: 7, appTitle: "Hades II",
                              steamGameName: nil, playedAt: t0)
        #expect(ResumePlan.make(last: nil, savedServerIDs: ["SRV1"], currentPath: []) == .nothingSaved)
        #expect(ResumePlan.make(last: last, savedServerIDs: [], currentPath: []) == .pcRemoved(name: "Omen"))
        #expect(ResumePlan.make(last: last, savedServerIDs: ["SRV1"],
                                currentPath: [.apps(serverUniqueID: "SRV1"), .stream(serverUniqueID: "SRV1", appID: 7)])
                == .alreadyPlaying)
        #expect(ResumePlan.make(last: last, savedServerIDs: ["SRV1"], currentPath: [])
                == .open(serverUniqueID: "SRV1", appID: 7))
        #expect(ResumePlan.nothingSaved.message == "Nothing to resume yet. Play a game in Pocket Rig first, then try again.")
        #expect(ResumePlan.pcRemoved(name: "Omen").message == "Omen isn't in Pocket Rig anymore. Add it again to resume.")
        #expect(ResumePlan.alreadyPlaying.message == nil)
    }

    // MARK: The app model

    @Test func openingAStreamRecordsTheLastGame() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        model.openStream(host, appID: 7, appTitle: "Desktop", steamGameName: "Baldur's Gate 3", now: t0)
        #expect(model.path == [.stream(serverUniqueID: "SRV1", appID: 7)])
        #expect(store.lastPlayed == LastPlayed(serverUniqueID: "SRV1", pcName: "Omen", appID: 7, appTitle: "Desktop",
                                               steamGameName: "Baldur's Gate 3", playedAt: t0))
    }

    @Test func reopeningTheSameAppKeepsTheSteamGameName() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        model.recordLaunch(host, appID: 7, appTitle: "Desktop", steamGameName: "Baldur's Gate 3", now: t0)
        model.recordLaunch(host, appID: 7, appTitle: "Desktop", steamGameName: nil, now: t0.addingTimeInterval(60))
        #expect(store.lastPlayed?.title == "Baldur's Gate 3")
        model.recordLaunch(host, appID: 9, appTitle: "Hades II", steamGameName: nil, now: t0.addingTimeInterval(120))
        #expect(store.lastPlayed?.title == "Hades II")
    }

    @Test func statusIsKeptOnlyForTheLastGamesPCAndNotTooOften() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        let other = try makeHost("SRV2", name: "Laptop", in: context)
        model.recordStatus(host, status: .offline, now: t0)
        #expect(store.pc == nil)   // no last game yet
        model.recordLaunch(host, appID: 7, appTitle: "Hades II", steamGameName: nil, now: t0)
        model.recordStatus(other, status: .offline, now: t0)
        #expect(store.pc == nil)   // a different PC
        model.recordStatus(host, status: .offline, now: t0)
        #expect(store.pc?.checkedAt == t0)
        model.recordStatus(host, status: .offline, now: t0.addingTimeInterval(60))
        #expect(store.pc?.checkedAt == t0)   // same status, too soon to write again
        model.recordStatus(host, status: .offline, now: t0.addingTimeInterval(301))
        #expect(store.pc?.checkedAt == t0.addingTimeInterval(301))
        model.recordStatus(host, status: .online(runningAppID: 0, runningTitle: nil, apps: []), now: t0.addingTimeInterval(302))
        #expect(store.pc?.state == .online)   // a change is written straight away
    }

    @Test func resumeGoesToTheAppListWithAPendingLaunch() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        model.recordLaunch(host, appID: 7, appTitle: "Hades II", steamGameName: nil, now: t0)
        model.path = [.apps(serverUniqueID: "OTHER")]
        #expect(model.resumeLastGame(hosts: [host]) == nil)
        #expect(model.path == [.apps(serverUniqueID: "SRV1")])
        #expect(model.pendingResume?.serverUniqueID == "SRV1")
        #expect(model.pendingResume?.appID == 7)
    }

    @Test func resumeExplainsWhenItCant() throws {
        let store = makeStore()
        let model = try makeModel(store)
        #expect(model.resumeLastGame(hosts: []) == ResumePlan.nothingSaved.message)
        store.lastPlayed = LastPlayed(serverUniqueID: "GONE", pcName: "Old PC", appID: 1, appTitle: "Desktop",
                                      steamGameName: nil, playedAt: t0)
        #expect(model.resumeLastGame(hosts: []) == "Old PC isn't in Pocket Rig anymore. Add it again to resume.")
        #expect(model.pendingResume == nil)
        #expect(model.path.isEmpty)
    }

    @Test func resumeWhileAlreadyPlayingThatGameDoesNothing() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        model.openStream(host, appID: 7, appTitle: "Hades II", now: t0)
        let path = model.path
        #expect(model.showStreamRequests == 0)
        #expect(model.resumeLastGame(hosts: [host]) == nil)
        #expect(model.path == path)
        #expect(model.pendingResume == nil)
        // The stream screen brings the game back out of the floating window, if it is in one.
        #expect(model.showStreamRequests == 1)
    }

    @Test func resumingAnotherGameDoesNotAskTheStreamScreenForAnything() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        model.recordLaunch(host, appID: 7, appTitle: "Hades II", steamGameName: nil, now: t0)
        model.path = [.apps(serverUniqueID: "SRV1")]
        _ = model.resumeLastGame(hosts: [host])
        #expect(model.showStreamRequests == 0)
    }

    @Test func anExpiredPendingResumeIsIgnoredAndCleared() throws {
        let model = try makeModel(makeStore())
        model.pendingResume = PendingLaunch(serverUniqueID: "SRV1", appID: 7, createdAt: t0)
        let late = t0.addingTimeInterval(PocketRigShared.resumeRequestLifetime + 1)
        #expect(model.takePendingResume(for: "SRV1", now: late) == nil)
        #expect(model.pendingResume == nil)
        model.pendingResume = PendingLaunch(serverUniqueID: "SRV1", appID: 7, createdAt: t0)
        #expect(model.takePendingResume(for: "SRV1", now: t0.addingTimeInterval(5))?.appID == 7)
        #expect(model.pendingResume == nil)   // taken once
    }

    @Test func aPendingResumeOnlyAppliesToItsOwnPC() throws {
        let model = try makeModel(makeStore())
        model.pendingResume = PendingLaunch(serverUniqueID: "SRV1", appID: 7, createdAt: t0)
        #expect(model.takePendingResume(for: "SRV2", now: t0) == nil)
        #expect(model.pendingResume != nil)   // still waiting for SRV1
        model.cancelPendingResume(for: "SRV2")
        #expect(model.pendingResume != nil)
    }

    @Test func aLoadFailureOrLeavingClearsThePendingResume() throws {
        let model = try makeModel(makeStore())
        model.pendingResume = PendingLaunch(serverUniqueID: "SRV1", appID: 7, createdAt: t0)
        model.cancelPendingResume(for: "SRV1")
        #expect(model.pendingResume == nil)
    }

    @Test func replacingTheListWithPairingClearsThePendingResume() throws {
        let model = try makeModel(makeStore())
        model.path = [.apps(serverUniqueID: "SRV1")]
        model.pendingResume = PendingLaunch(serverUniqueID: "SRV1", appID: 7, createdAt: t0)
        model.replaceTop(.apps(serverUniqueID: "SRV1"), with: .pair(serverUniqueID: "SRV1"))
        #expect(model.pendingResume == nil)
    }

    @Test func aNewLastGameOnAnotherPCClearsTheOldPCsStatus() throws {
        let store = makeStore()
        let model = try makeModel(store)
        let context = try makeContext()
        let host = try makeHost(in: context)
        let other = try makeHost("SRV2", name: "Laptop", in: context)
        model.recordLaunch(host, appID: 7, appTitle: "Hades II", steamGameName: nil, now: t0)
        model.recordStatus(host, status: .offline, now: t0)
        #expect(store.pc?.serverUniqueID == "SRV1")
        model.recordLaunch(host, appID: 9, appTitle: "Other", steamGameName: nil, now: t0.addingTimeInterval(1))
        #expect(store.pc?.serverUniqueID == "SRV1")   // same PC keeps its status
        model.recordLaunch(other, appID: 3, appTitle: "Desktop", steamGameName: nil, now: t0.addingTimeInterval(2))
        #expect(store.pc == nil)
    }

    @Test func theIntentWritesARequestAndOpensTheApp() async throws {
        // The test host is the running app: it would take a request written to the real storage first.
        let store = makeStore()
        let original = ResumeLastGameIntent.store
        ResumeLastGameIntent.store = { store }
        defer { ResumeLastGameIntent.store = original }
        _ = try await ResumeLastGameIntent().perform()
        #expect(store.takeResumeRequest(now: .now))
    }
}
