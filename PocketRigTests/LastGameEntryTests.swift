import Foundation
import Testing
@testable import PocketRig

@Suite struct LastGameEntryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var last: LastPlayed {
        LastPlayed(serverUniqueID: "SRV1", pcName: "Omen", appID: 7, appTitle: "Desktop",
                   steamGameName: "Baldur's Gate 3", playedAt: t0)
    }

    @Test func nothingPlayedYetShowsGuidance() {
        let entry = LastGameEntry.make(lastPlayed: nil, pc: nil, now: t0)
        #expect(entry.game == nil)
        #expect(entry.date == t0)
        #expect(LastGameEntry.emptyMessage == "Play a game in Pocket Rig and it shows up here.")
    }

    @Test func theLastGameShowsWithItsPCsStatus() {
        let pc = PCSnapshot(serverUniqueID: "SRV1", pcName: "Omen", state: .online, runningTitle: "Desktop",
                            checkedAt: t0.addingTimeInterval(-60))
        let entry = LastGameEntry.make(lastPlayed: last, pc: pc, now: t0)
        #expect(entry.game == LastGameEntry.Game(title: "Baldur's Gate 3", pcName: "Omen", status: "Playing Desktop",
                                                 checkedAt: t0.addingTimeInterval(-60)))
    }

    @Test func anotherPCsStatusIsNotShown() {
        let pc = PCSnapshot(serverUniqueID: "SRV2", pcName: "Laptop", state: .offline, runningTitle: nil, checkedAt: t0)
        let entry = LastGameEntry.make(lastPlayed: last, pc: pc, now: t0)
        #expect(entry.game?.status == nil)
        #expect(entry.game?.checkedAt == nil)
    }

    @Test func aStatusOlderThanAnHourIsHidden() {
        let old = PCSnapshot(serverUniqueID: "SRV1", pcName: "Omen", state: .online, runningTitle: nil,
                             checkedAt: t0.addingTimeInterval(-3601))
        let hidden = LastGameEntry.make(lastPlayed: last, pc: old, now: t0)
        #expect(hidden.game?.status == nil)
        #expect(hidden.game?.checkedAt == nil)
        #expect(hidden.game?.pcName == "Omen")
        let edge = PCSnapshot(serverUniqueID: "SRV1", pcName: "Omen", state: .online, runningTitle: nil,
                              checkedAt: t0.addingTimeInterval(-3600))
        #expect(LastGameEntry.make(lastPlayed: last, pc: edge, now: t0).game?.status == "Online")
    }

    @Test func justNowMeansUnderAMinute() {
        let g = LastGameEntry.Game(title: "X", pcName: "Omen", status: "Online", checkedAt: t0)
        #expect(g.isJustChecked(at: t0.addingTimeInterval(59)))
        #expect(!g.isJustChecked(at: t0.addingTimeInterval(60)))
        #expect(!LastGameEntry.Game(title: "X", pcName: "Omen", status: nil, checkedAt: nil).isJustChecked(at: t0))
    }

    @Test func itReadsTheSharedStore() {
        let store = SharedStore(defaults: UserDefaults(suiteName: "pocketrig-tests-\(UUID().uuidString)")!)
        #expect(LastGameEntry.make(store: store, now: t0).game == nil)
        store.lastPlayed = last
        #expect(LastGameEntry.make(store: store, now: t0).game?.title == "Baldur's Gate 3")
    }

    @Test func theSampleHasAGame() {
        #expect(LastGameEntry.sample.game != nil)
        #expect(LastGameEntry.empty.game == nil)
    }
}
