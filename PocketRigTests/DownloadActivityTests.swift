import Foundation
import SwiftData
import Testing
@testable import PocketRig

typealias DownloadState = DownloadActivityAttributes.ContentState

@MainActor final class FakeDownloadActivities: DownloadActivityHosting {
    var isEnabled = true
    var all: [ShownDownloadActivity] = []
    var shown: ShownDownloadActivity? {
        get { all.first }
        set { all = newValue.map { [$0] } ?? [] }
    }
    var failStarts = false
    var starts: [(attributes: DownloadActivityAttributes, state: DownloadState, stale: Date)] = []
    var updates: [(id: String, state: DownloadState, stale: Date)] = []
    var ends: [(id: String, state: DownloadState, dismissAt: Date)] = []

    func existing() -> [ShownDownloadActivity] { all }

    func start(_ attributes: DownloadActivityAttributes, state: DownloadState, staleDate: Date) async -> String? {
        starts.append((attributes, state, staleDate))
        if failStarts { return nil }
        return "A\(starts.count)"
    }

    func update(id: String, state: DownloadState, staleDate: Date) async { updates.append((id, state, staleDate)) }
    func end(id: String, state: DownloadState, dismissAt: Date) async { ends.append((id, state, dismissAt)) }
}

/// A Helper with downloads (Dota 2 downloading at 40 %, Baldur's Gate 3 waiting).
private struct DownloadingHelper: HelperRequesting {
    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        switch path {
        case "/v1/info": (Data(HelperFixtures.readyInfo.utf8), 200)
        case "/v1/downloads": (Data(HelperFixtures.downloads.utf8), 200)
        default: throw HelperError.unreachable
        }
    }
}

@Suite @MainActor struct DownloadActivityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func download(_ id: Int, _ name: String, _ state: HelperGame.State, done: Int64 = 40, total: Int64 = 100) -> HelperDownload {
        HelperDownload(appID: id, name: name, state: state, bytesDownloaded: done, bytesToDownload: total, headerURL: nil)
    }

    // MARK: What it shows

    @Test func theDownloadingGameLeadsAndTheRestWait() throws {
        let list: [HelperDownload] = try HelperFixtures.decode(HelperFixtures.downloads, as: DownloadsReply.self).downloads
        let state = try #require(DownloadActivityPlan.content(for: list))
        #expect(state.name == "Dota 2")
        #expect(state.progress == 0.4)
        #expect(state.statusText == "Downloading")
        #expect(state.waitingCount == 1)
        #expect(state.waitingText == "1 more waiting")
        #expect(state.percentText == "40%")
        #expect(!state.finished)
    }

    @Test func pausedComesBeforeWaitingAndInstalledIsIgnored() {
        let state = DownloadActivityPlan.content(for: [download(1, "A", .queued), download(2, "B", .paused),
                                                       download(3, "C", .installed)])
        #expect(state?.name == "B")
        #expect(state?.statusText == "Paused")
        #expect(state?.waitingCount == 1)
        #expect(DownloadActivityPlan.content(for: [download(3, "C", .installed)]) == nil)
        #expect(DownloadActivityPlan.content(for: []) == nil)
    }

    @Test func progressMovesInWholePercents() {
        let state = DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 40_49, total: 10_000)])
        #expect(state?.progress == 0.4)
        #expect(DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 0, total: 0)])?.progress == 0)
    }

    @Test func steps() {
        let a = [download(1, "A", .downloading)]
        let first = DownloadActivityPlan.content(for: a)!
        #expect(DownloadActivityPlan.step(current: nil, downloads: a) == .start(first))
        #expect(DownloadActivityPlan.step(current: first, downloads: a) == .none)
        let later = [download(1, "A", .downloading, done: 50)]
        #expect(DownloadActivityPlan.step(current: first, downloads: later) == .update(DownloadActivityPlan.content(for: later)!))
        #expect(DownloadActivityPlan.step(current: nil, downloads: []) == .none)
    }

    @Test func anAlmostDoneDownloadThatLeavesTheListIsReadyToPlay() {
        let nearly = DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 97)])!
        guard case .finish(let done) = DownloadActivityPlan.step(current: nearly, downloads: []) else {
            Issue.record("expected finish")
            return
        }
        #expect(done.finished)
        #expect(done.progress == 1)
        #expect(done.statusText == "Ready to play")
        #expect(done.percentText == "Done")
        #expect(done.waitingCount == 0)
    }

    @Test func aDownloadThatStopsEarlyDoesNotClaimItsDone() {
        let half = DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 50)])!
        guard case .finish(let stopped) = DownloadActivityPlan.step(current: half, downloads: []) else {
            Issue.record("expected finish")
            return
        }
        #expect(stopped.statusText == "Stopped downloading")
        #expect(stopped.progress == 0.5)
        #expect(stopped.percentText == "50%")
    }

    @Test func afterAFinishANewDownloadStartsAFreshActivity() {
        let done = DownloadState(appID: 1, name: "A", progress: 1, statusText: "Ready to play", waitingCount: 0, finished: true)
        let next = [download(2, "B", .downloading)]
        #expect(DownloadActivityPlan.step(current: done, downloads: next) == .start(DownloadActivityPlan.content(for: next)!))
        #expect(DownloadActivityPlan.step(current: done, downloads: []) == .none)
    }

    // MARK: The controller

    @Test func startsOnceThenUpdatesOnlyOnChange() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)],
                          now: t0.addingTimeInterval(10))
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 1)
        #expect(fake.starts.first?.attributes.pcName == "Omen")
        #expect(fake.starts.first?.stale == t0.addingTimeInterval(DownloadActivityController.staleAfter))
        #expect(fake.updates.isEmpty)
        #expect(controller.isShowing)

        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading, done: 60)],
                          now: t0.addingTimeInterval(20))
        await controller.waitUntilIdle()
        #expect(fake.updates.map(\.id) == ["A1"])
        #expect(fake.updates.first?.state.progress == 0.6)
    }

    @Test func anUnchangedDownloadIsTouchedSoItDoesNotGoStaleWhileTheAppChecks() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        let list = [download(1, "A", .paused)]
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: list, now: t0)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: list,
                          now: t0.addingTimeInterval(DownloadActivityController.refreshEvery + 1))
        await controller.waitUntilIdle()
        #expect(fake.updates.count == 1)
        #expect(fake.updates.first?.stale == t0.addingTimeInterval(DownloadActivityController.refreshEvery + 1
                                                                     + DownloadActivityController.staleAfter))
    }

    @Test func aFinishedDownloadStaysTenMinutes() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading, done: 99)], now: t0)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [], now: t0.addingTimeInterval(5))
        await controller.waitUntilIdle()
        #expect(fake.ends.count == 1)
        #expect(fake.ends.first?.id == "A1")
        #expect(fake.ends.first?.state.statusText == "Ready to play")
        #expect(fake.ends.first?.dismissAt == t0.addingTimeInterval(5 + DownloadActivityController.finishedStays))
        #expect(!controller.isShowing)
        // Nothing more to end.
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [], now: t0.addingTimeInterval(10))
        await controller.waitUntilIdle()
        #expect(fake.ends.count == 1)
    }

    @Test func itFollowsOnePCAtATime() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)], now: t0)
        // The other PC having nothing doesn't end this one.
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 1)
        #expect(fake.ends.isEmpty)
        #expect(controller.current?.name == "A")
    }

    @Test func afterOnePCFinishesAnotherPCCanTakeOver() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading, done: 99)], now: t0)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [], now: t0)
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.starts.map(\.attributes.pcName) == ["Omen", "Laptop"])
        // The finished one is taken away now, so only one shows.
        #expect(fake.ends.last?.id == "A1")
        #expect(fake.ends.last?.dismissAt == t0)
    }

    @Test func anActivityLeftFromBeforeIsPickedUp() async {
        let fake = FakeDownloadActivities()
        let old = DownloadActivityPlan.content(for: [download(1, "A", .downloading)])!
        fake.shown = ShownDownloadActivity(id: "OLD", serverUniqueID: "SRV1", state: old)
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading, done: 70)], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.starts.isEmpty)
        #expect(fake.updates.map(\.id) == ["OLD"])
    }

    @Test func aPCThatGoesSilentHandsOverToAnother() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        // 60 s of quiet is not enough.
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)],
                          now: t0.addingTimeInterval(60))
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 1)
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)],
                          now: t0.addingTimeInterval(DownloadActivityController.staleAfter + 1))
        await controller.waitUntilIdle()
        #expect(fake.starts.map(\.attributes.pcName) == ["Omen", "Laptop"])
        #expect(fake.ends.map(\.id) == ["A1"])
        #expect(fake.ends.first?.dismissAt == t0.addingTimeInterval(DownloadActivityController.staleAfter + 1))
        #expect(controller.current?.name == "B")
    }

    @Test func anActivityFromBeforeCountsAsStaleUntilItIsRefreshed() async {
        let fake = FakeDownloadActivities()
        fake.shown = ShownDownloadActivity(id: "OLD", serverUniqueID: "SRV1",
                                           state: DownloadActivityPlan.content(for: [download(1, "A", .downloading)])!)
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.ends.map(\.id) == ["OLD"])
        #expect(fake.starts.map(\.attributes.pcName) == ["Laptop"])
    }

    @Test func aFollowedPCThatIsNoLongerCheckedLosesItsActivity() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        controller.keepOnly(serverUniqueIDs: ["SRV1", "SRV2"], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.ends.isEmpty)
        controller.keepOnly(serverUniqueIDs: ["SRV2"], now: t0.addingTimeInterval(5))
        await controller.waitUntilIdle()
        #expect(fake.ends.map(\.id) == ["A1"])
        #expect(fake.ends.first?.dismissAt == t0.addingTimeInterval(5))
        #expect(!controller.isShowing)
        // The next PC can start straight away.
        controller.update(serverUniqueID: "SRV2", pcName: "Laptop", downloads: [download(2, "B", .downloading)],
                          now: t0.addingTimeInterval(6))
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 2)
    }

    @Test func pickingUpAnOldActivityClosesTheExtras() async {
        let fake = FakeDownloadActivities()
        let state = DownloadActivityPlan.content(for: [download(1, "A", .downloading)])!
        fake.all = [ShownDownloadActivity(id: "ONE", serverUniqueID: "SRV1", state: state),
                    ShownDownloadActivity(id: "TWO", serverUniqueID: "SRV1", state: state),
                    ShownDownloadActivity(id: "THREE", serverUniqueID: "SRV2", state: state)]
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading, done: 70)], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.ends.map(\.id) == ["TWO", "THREE"])
        #expect(fake.ends.allSatisfy { $0.dismissAt == t0 })
        #expect(fake.updates.map(\.id) == ["ONE"])
    }

    @Test func almostDoneNeverReadsAsOneHundredPercent() {
        let state = DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 996, total: 1000)])
        #expect(state?.progress == 0.99)
        #expect(state?.percentText == "99%")
        let over = DownloadActivityPlan.content(for: [download(1, "A", .downloading, done: 120, total: 100)])
        #expect(over?.percentText == "99%")
    }

    @Test func aFailedStartWaitsAMinuteBeforeTryingAgain() async {
        let fake = FakeDownloadActivities()
        fake.failStarts = true
        let controller = DownloadActivityController(hosting: fake)
        let list = [download(1, "A", .downloading)]
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: list, now: t0)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: list, now: t0.addingTimeInterval(10))
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 1)
        fake.failStarts = false
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: list,
                          now: t0.addingTimeInterval(DownloadActivityController.startRetryAfter + 1))
        await controller.waitUntilIdle()
        #expect(fake.starts.count == 2)
        #expect(controller.isShowing)
    }

    @Test func turningLiveActivitiesOffEndsTheOneShowing() async {
        let fake = FakeDownloadActivities()
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        await controller.waitUntilIdle()
        #expect(controller.isShowing)
        fake.isEnabled = false
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)],
                          now: t0.addingTimeInterval(5))
        await controller.waitUntilIdle()
        #expect(fake.ends.map(\.id) == ["A1"])
        #expect(!controller.isShowing)
    }

    @Test func liveActivitiesTurnedOffMeansNothingHappens() async {
        let fake = FakeDownloadActivities()
        fake.isEnabled = false
        let controller = DownloadActivityController(hosting: fake)
        controller.update(serverUniqueID: "SRV1", pcName: "Omen", downloads: [download(1, "A", .downloading)], now: t0)
        await controller.waitUntilIdle()
        #expect(fake.starts.isEmpty)
        #expect(!controller.isShowing)
    }

    @Test func readingDownloadsFeedsTheActivity() async throws {
        let container = try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let host = Host(serverUniqueID: "SRV1", name: "Omen", lanAddress: "192.168.1.50", tailscaleAddress: nil)
        host.serverCertPEM = Data("PEM".utf8)
        context.insert(host)
        try context.save()
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in HelperClient(requester: DownloadingHelper()) })
        let fake = FakeDownloadActivities()
        model.downloadActivities = DownloadActivityController(hosting: fake)
        await model.refreshHelper(host, preferredAddress: nil)
        await model.refreshDownloads(host)
        await model.downloadActivities.waitUntilIdle()
        #expect(fake.starts.count == 1)
        #expect(fake.starts.first?.attributes.serverUniqueID == "SRV1")
        #expect(fake.starts.first?.state.name == "Dota 2")
    }

    @Test func theDefaultModelShowsNoActivity() throws {
        let model = try AppModel(identity: HelperFixtures.identity(), makeRequester: { _, _ in StubRequester() })
        #expect(!model.downloadActivities.isShowing)
    }
}

private struct DownloadsReply: Decodable { let downloads: [HelperDownload] }
