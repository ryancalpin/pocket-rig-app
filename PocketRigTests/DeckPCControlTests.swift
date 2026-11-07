import Testing
@testable import PocketRig

/// The Quick menu's PC controls run inside `DeckModel`, so they survive switching deck tabs.
@Suite @MainActor struct DeckPCControlTests {
    private func makeDeck() -> DeckModel {
        DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
    }

    private func slow(_ deck: DeckModel, calls: Counter) {
        deck.onPCControl = { control in
            calls.count += 1
            try? await Task.sleep(for: .milliseconds(150))
            return PCControlResult(message: control.doneMessage, succeeded: true)
        }
    }

    @MainActor final class Counter { var count = 0 }

    @Test func aSecondSendWhileOneRunsIsIgnored() async {
        let deck = makeDeck()
        let calls = Counter()
        slow(deck, calls: calls)
        deck.runPCControl(.lock)
        deck.runPCControl(.sleep)
        #expect(deck.runningControl == .lock)
        await deck.controlTask?.value
        #expect(calls.count == 1)
        #expect(deck.runningControl == nil)
    }

    @Test func theResultSurvivesSwitchingTabs() async {
        let deck = makeDeck()
        deck.select(.quickMenu)
        slow(deck, calls: Counter())
        deck.runPCControl(.lock)
        deck.select(.stats)
        #expect(deck.runningControl == .lock)
        await deck.controlTask?.value
        deck.select(.quickMenu)
        #expect(deck.runningControl == nil)
        #expect(deck.pcNotice?.message == PCControl.lock.doneMessage)
        #expect(deck.pcNotice?.succeeded == true)
    }

    /// The success or error haptic follows the result, not the tab: it comes once, as the result arrives,
    /// even when the Quick menu isn't on screen, and not again when the notice is shown once more.
    @Test func theResultHapticComesOnAnyTabAndOnlyOnce() async throws {
        let deck = makeDeck()
        deck.select(.gamepad)
        slow(deck, calls: Counter())
        deck.runPCControl(.lock)
        await deck.controlTask?.value
        let feedback = try #require(deck.resultFeedback)
        #expect(feedback.succeeded)
        deck.select(.quickMenu)
        deck.restartNoticeTimer()
        #expect(deck.resultFeedback == feedback)
        deck.onPCControl = { _ in PCControlResult(message: "Sign in to Steam on your PC first.", succeeded: false) }
        deck.select(.stats)
        deck.runPCControl(.restartSteam)
        await deck.controlTask?.value
        #expect(deck.resultFeedback?.succeeded == false)
        #expect(deck.resultFeedback != feedback)
    }

    @Test func leavingTheScreenCancelsQuietly() async {
        let deck = makeDeck()
        slow(deck, calls: Counter())
        deck.runPCControl(.restart)
        let task = deck.controlTask
        deck.stopPCControl()
        await task?.value
        #expect(deck.runningControl == nil)
        #expect(deck.pcNotice == nil)
    }

    @Test func aFailureAsksForAnotherLookAtTheHelper() async {
        let deck = makeDeck()
        var refreshes = 0
        deck.onPCControlFailed = { refreshes += 1 }
        deck.onPCControl = { _ in PCControlResult(message: "Sign in to Steam on your PC first.", succeeded: false) }
        deck.runPCControl(.restartSteam)
        await deck.controlTask?.value
        #expect(refreshes == 1)
        #expect(deck.pcNotice?.succeeded == false)
        deck.onPCControl = { control in PCControlResult(message: control.doneMessage, succeeded: true) }
        deck.runPCControl(.lock)
        await deck.controlTask?.value
        #expect(refreshes == 1)
    }

    @Test func sleepPromisesWakeOnlyWhenTheAppCanDoIt() throws {
        let deck = makeDeck()
        let ready = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.readyInfo))
        let noCable = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.freshInfo))
        deck.helper = ready
        #expect(!deck.canWakeAfterSleep)           // no saved network-card address yet
        deck.hasSavedWakeAddress = true
        deck.streamAddress = "192.168.1.50"
        #expect(deck.canWakeAfterSleep)
        deck.streamAddress = "100.101.102.103"        // over Tailscale a sleeping PC can't be woken
        #expect(!deck.canWakeAfterSleep)
        deck.streamAddress = nil
        #expect(deck.canWakeAfterSleep)
        deck.helper = noCable
        #expect(!deck.canWakeAfterSleep)
    }
}
