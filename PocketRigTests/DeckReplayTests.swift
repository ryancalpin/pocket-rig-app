import Testing
@testable import PocketRig

/// "Save last 30 seconds" runs inside `DeckModel`, so it survives switching deck tabs, like PC controls.
@Suite @MainActor struct DeckReplayTests {
    @MainActor final class Counter { var count = 0 }

    private func makeDeck(_ calls: Counter, result: ReplayResult = .saved(seconds: 30)) -> DeckModel {
        let deck = DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
        deck.onSaveReplay = {
            calls.count += 1
            try? await Task.sleep(for: .milliseconds(100))
            return result
        }
        return deck
    }

    @Test func aSecondTapWhileSavingIsIgnored() async {
        let calls = Counter()
        let deck = makeDeck(calls)
        deck.saveReplay()
        deck.saveReplay()
        #expect(deck.isSavingReplay)
        await deck.replayTask?.value
        #expect(calls.count == 1)
        #expect(!deck.isSavingReplay)
    }

    @Test func theResultShowsAsTheQuickMenuNotice() async {
        let deck = makeDeck(Counter())
        deck.saveReplay()
        await deck.replayTask?.value
        #expect(deck.pcNotice?.message == "Saved the last 30 seconds to Photos")
        #expect(deck.pcNotice?.succeeded == true)
    }

    @Test func aFailureSaysSoAndSurvivesSwitchingTabs() async {
        let deck = makeDeck(Counter(), result: .noPermission)
        deck.select(.quickMenu)
        deck.saveReplay()
        deck.select(.stats)
        await deck.replayTask?.value
        #expect(deck.pcNotice?.message == ReplayResult.noPermission.message)
        #expect(deck.pcNotice?.succeeded == false)
    }

    @Test func leavingTheStreamStopsWaitingQuietly() async {
        let deck = makeDeck(Counter())
        deck.saveReplay()
        deck.stopPCControl()
        await deck.replayTask?.value
        #expect(!deck.isSavingReplay)
        #expect(deck.pcNotice == nil)
    }

    @Test func theTileWaitsForASecondOfVideo() async throws {
        let deck = makeDeck(Counter())
        deck.replayReadyDelay = .milliseconds(100)
        #expect(!deck.replayReady)
        deck.isLive = true
        #expect(!deck.replayReady)
        try await Task.sleep(for: .milliseconds(400))
        #expect(deck.replayReady)
        deck.isLive = false
        #expect(!deck.replayReady)
    }

    @Test func goingOfflineBeforeTheDelayKeepsTheTileOff() async throws {
        let deck = makeDeck(Counter())
        deck.replayReadyDelay = .milliseconds(100)
        deck.isLive = true
        deck.isLive = false
        try await Task.sleep(for: .milliseconds(400))
        #expect(!deck.replayReady)
    }

    @Test func aCancelledSavesLateReturnChangesNothing() async throws {
        let deck = DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
        deck.onSaveReplay = {
            try? await Task.sleep(for: .milliseconds(150))
            return .saved(seconds: 30)
        }
        deck.saveReplay()
        let first = deck.replayTask
        deck.stopPCControl()
        deck.onSaveReplay = {
            try? await Task.sleep(for: .milliseconds(600))
            return .saved(seconds: 30)
        }
        deck.saveReplay()
        #expect(deck.isSavingReplay)
        await first?.value                       // the first save returns late
        #expect(deck.isSavingReplay)             // the second save is still running
        #expect(deck.pcNotice == nil)
        deck.stopPCControl()
    }
}
