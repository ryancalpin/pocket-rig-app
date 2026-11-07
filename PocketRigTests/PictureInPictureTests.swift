import AVKit
import SwiftUI
import Testing
@testable import PocketRig

@Suite @MainActor struct PictureInPictureTests {
    @Test func leavingTheScreenWithoutPictureInPicturePauses() {
        #expect(StreamBackgroundRule.onPhase(.background, isRunning: true, inPictureInPicture: false,
                                             pausedForBackground: false) == .pause)
    }

    @Test func leavingTheScreenInPictureInPictureKeepsPlaying() {
        #expect(StreamBackgroundRule.onPhase(.background, isRunning: true, inPictureInPicture: true,
                                             pausedForBackground: false) == .nothing)
    }

    @Test func nothingToPauseWhenNoStreamRuns() {
        #expect(StreamBackgroundRule.onPhase(.background, isRunning: false, inPictureInPicture: false,
                                             pausedForBackground: false) == .nothing)
    }

    @Test func comingBackResumesOnlyAPausedStream() {
        #expect(StreamBackgroundRule.onPhase(.active, isRunning: false, inPictureInPicture: false,
                                             pausedForBackground: true) == .resume)
        #expect(StreamBackgroundRule.onPhase(.active, isRunning: true, inPictureInPicture: false,
                                             pausedForBackground: false) == .nothing)
        // Inactive (Control Center pulled down, a call banner) is not leaving.
        #expect(StreamBackgroundRule.onPhase(.inactive, isRunning: true, inPictureInPicture: false,
                                             pausedForBackground: false) == .nothing)
    }

    @Test func closingTheFloatingWindowInTheBackgroundPauses() {
        #expect(StreamBackgroundRule.onPictureInPictureStop(restored: false, appIsActive: false, isRunning: true) == .pause)
    }

    @Test func goingBackToTheAppTurnsTheControlsBackOn() {
        #expect(StreamBackgroundRule.onPictureInPictureStop(restored: true, appIsActive: false, isRunning: true) == .resumeInput)
        #expect(StreamBackgroundRule.onPictureInPictureStop(restored: false, appIsActive: true, isRunning: true) == .resumeInput)
        #expect(StreamBackgroundRule.onPictureInPictureStop(restored: false, appIsActive: false, isRunning: false) == .nothing)
    }

    @Test func theControllerExistsExactlyWherePictureInPictureWorks() {
        let made = StreamPictureInPicture(layer: AVSampleBufferDisplayLayer())
        #expect((made != nil) == AVPictureInPictureController.isPictureInPictureSupported())
    }

    @Test func theDeckHidesTheTileUntilTheStreamScreenSaysSo() {
        let deck = DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
        #expect(!deck.canPictureInPicture)
    }

    // MARK: Fixes after review

    @Test func tappingTheAppIconInTheWindowIsAReturnNotALeave() {
        // Inactive: the app is on its way back; the stream must keep going.
        #expect(StreamBackgroundRule.onPictureInPictureStop(restored: false, appIsActive: false, isRunning: true,
                                                            appIsInactive: true) == .resumeInput)
    }

    @Test func aLateWindowGetsOneMoreGracePeriod() {
        #expect(StreamBackgroundRule.shouldWaitForLateStart(pictureInPicturePossible: true, autoStartAllowed: true,
                                                            alreadyExtended: false))
        #expect(!StreamBackgroundRule.shouldWaitForLateStart(pictureInPicturePossible: true, autoStartAllowed: true,
                                                             alreadyExtended: true))
        #expect(!StreamBackgroundRule.shouldWaitForLateStart(pictureInPicturePossible: false, autoStartAllowed: true,
                                                             alreadyExtended: false))
        #expect(!StreamBackgroundRule.shouldWaitForLateStart(pictureInPicturePossible: true, autoStartAllowed: false,
                                                             alreadyExtended: false))
    }

    @Test func aPausedStreamThatEndedWithTheAppBackRestartsUnlessAResumeIsComing() {
        #expect(StreamBackgroundRule.shouldRestartAfterEnd(pausedForBackground: true, appIsActive: true, resumeScheduled: false))
        #expect(!StreamBackgroundRule.shouldRestartAfterEnd(pausedForBackground: true, appIsActive: true, resumeScheduled: true))
        #expect(!StreamBackgroundRule.shouldRestartAfterEnd(pausedForBackground: true, appIsActive: false, resumeScheduled: false))
        #expect(!StreamBackgroundRule.shouldRestartAfterEnd(pausedForBackground: false, appIsActive: true, resumeScheduled: false))
    }

    @Test func returningWhileThePauseIsStillStoppingResumesExactlyOnce() async {
        let log = EventLog()
        let queue = StreamLifecycleQueue()
        queue.pause {
            await log.add("stop begins")
            try? await Task.sleep(for: .milliseconds(80))   // teardown takes a while
            await log.add("stop ends")
        }
        queue.resume(shouldRun: { true }) { await log.add("start") }
        #expect(queue.pendingResumes == 1)
        await queue.waitUntilIdle()
        #expect(await log.events == ["stop begins", "stop ends", "start"])
        #expect(queue.pendingResumes == 0)
    }

    @Test func aResumeSkipsItsStartWhenTheAppLeftAgainAndAfterClosing() async {
        let log = EventLog()
        let queue = StreamLifecycleQueue()
        queue.resume(shouldRun: { false }) { await log.add("start") }
        await queue.waitUntilIdle()
        #expect(await log.events.isEmpty)
        queue.resume(shouldRun: { true }) { await log.add("start") }
        queue.close { await log.add("final stop") }
        await queue.waitUntilIdle()
        // Closing turns every queued resume into a no-op; only the final stop runs.
        queue.resume(shouldRun: { true }) { await log.add("late start") }
        await queue.waitUntilIdle()
        #expect(await log.events == ["final stop"])
    }

    @Test func aStopDoesNotWaitForAStartThatIsStillConnecting() async {
        let log = EventLog()
        let queue = StreamLifecycleQueue()
        queue.resume(shouldRun: { true }) {
            await log.add("start begins")
            try? await Task.sleep(for: .milliseconds(150))   // a slow handshake
            await log.add("start ends")
        }
        for _ in 0..<100 where await log.events.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        queue.close { await log.add("final stop") }
        for _ in 0..<100 where await !log.events.contains("final stop") { try? await Task.sleep(for: .milliseconds(5)) }
        // The stop ran while the start was still connecting, not after it.
        #expect(await log.events == ["start begins", "final stop"])
        await queue.waitUntilIdle()
    }

    @Test func aResumeWaitingBehindAStopIsDroppedWhenTheAppLeavesAgain() async {
        let log = EventLog()
        let queue = StreamLifecycleQueue()
        queue.pause {
            try? await Task.sleep(for: .milliseconds(60))
            await log.add("stop 1")
        }
        queue.resume(shouldRun: { true }) { await log.add("start") }
        queue.pause { await log.add("stop 2") }
        await queue.waitUntilIdle()
        #expect(await !log.events.contains("start"))
        #expect(queue.pendingResumes == 0)
    }

    // MARK: Fixes after the final review

    @Test func aQualityReconnectRunsOnlyWhileThePlayerWatchesTheFullScreen() {
        #expect(StreamBackgroundRule.canReconnect(appIsActive: true, inPictureInPicture: false))
        #expect(!StreamBackgroundRule.canReconnect(appIsActive: true, inPictureInPicture: true))   // window from the Quick menu
        #expect(!StreamBackgroundRule.canReconnect(appIsActive: false, inPictureInPicture: true))  // floating over the home screen
        #expect(!StreamBackgroundRule.canReconnect(appIsActive: false, inPictureInPicture: false)) // in the background
    }

    @Test func heatAndDataNoticesShowOnlyWhereTheyCanBeRead() {
        #expect(StreamBackgroundRule.canShowNotice(appIsActive: true, inPictureInPicture: false))
        #expect(!StreamBackgroundRule.canShowNotice(appIsActive: true, inPictureInPicture: true))
        #expect(!StreamBackgroundRule.canShowNotice(appIsActive: false, inPictureInPicture: false))
    }

    @Test func aRefitBetweenConnectionsCountsAsRunningSoLeavingStopsIt() {
        // A failed refit waiting to retry: leaving pauses it, instead of a retry starting it unwatched.
        #expect(StreamBackgroundRule.isRunning(.failed(.startFailed), refitUnderway: true))
        #expect(StreamBackgroundRule.isRunning(.idle, refitUnderway: true))   // between the stop and the start
        #expect(StreamBackgroundRule.onPhase(.background,
                                             isRunning: StreamBackgroundRule.isRunning(.failed(.startFailed), refitUnderway: true),
                                             inPictureInPicture: false, pausedForBackground: false) == .pause)
        // Without a refit, a failed or ended stream isn't running; a live one always is.
        #expect(!StreamBackgroundRule.isRunning(.failed(.startFailed), refitUnderway: false))
        #expect(!StreamBackgroundRule.isRunning(.ended, refitUnderway: false))
        #expect(!StreamBackgroundRule.isRunning(nil, refitUnderway: false))
        #expect(StreamBackgroundRule.isRunning(.streaming, refitUnderway: false))
        #expect(StreamBackgroundRule.isRunning(.connecting(stage: "Starting"), refitUnderway: false))
    }

    @Test func thePictureInPictureTileSaysSoWhenTheWindowCantOpenYet() {
        let deck = DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
        deck.onPictureInPicture = { false }
        deck.startPictureInPicture()
        #expect(deck.pcNotice?.message == "Picture in picture isn't ready yet. Try again in a moment.")
        #expect(deck.pcNotice?.succeeded == false)
    }

    @Test func thePictureInPictureTileIsQuietWhenTheWindowOpens() {
        let deck = DeckModel(gamepad: GamepadInput(sender: RecordingSender()))
        var asked = 0
        deck.onPictureInPicture = { asked += 1; return true }
        deck.startPictureInPicture()
        #expect(asked == 1)
        #expect(deck.pcNotice == nil)
    }
}

private actor EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}
