import SwiftUI

enum StreamBackgroundAction: Equatable, Sendable {
    case nothing
    /// Stop the stream; nobody is watching.
    case pause
    /// Start the paused stream again (same game).
    case resume
    /// Picture in picture ended with the app in front: turn the controls back on.
    case resumeInput
}

/// What a stream does when the app leaves or comes back to the screen. In picture in picture it keeps
/// playing; otherwise it stops, so it doesn't run (and use data) with nobody watching.
enum StreamBackgroundRule {
    /// Picture in picture starts as the app leaves the screen; wait this long before deciding to pause.
    static let graceDelay: Duration = .seconds(1)

    /// `isRunning`: a stream is starting or playing (not ended, failed or paused).
    static func onPhase(_ phase: ScenePhase, isRunning: Bool, inPictureInPicture: Bool,
                        pausedForBackground: Bool) -> StreamBackgroundAction {
        switch phase {
        case .background: isRunning && !inPictureInPicture ? .pause : .nothing
        case .active: pausedForBackground ? .resume : .nothing
        default: .nothing
        }
    }

    /// `restored`: the user tapped the window's "back to app" button.
    /// `appIsInactive`: the app is on its way back (tapping the app icon in the window passes through inactive).
    static func onPictureInPictureStop(restored: Bool, appIsActive: Bool, isRunning: Bool,
                                       appIsInactive: Bool = false) -> StreamBackgroundAction {
        if restored || appIsActive || appIsInactive { return .resumeInput }
        return isRunning ? .pause : .nothing
    }

    /// The grace period ended with no window yet. If the system could still open one, give it one more
    /// grace period (once) rather than pausing a stream that is about to float.
    static func shouldWaitForLateStart(pictureInPicturePossible: Bool, autoStartAllowed: Bool,
                                       alreadyExtended: Bool) -> Bool {
        pictureInPicturePossible && autoStartAllowed && !alreadyExtended
    }

    /// A stream that was paused for the background has finished stopping. If the app is already back and no
    /// resume is on its way, start it here, so it never sits on "Reconnecting" for good.
    static func shouldRestartAfterEnd(pausedForBackground: Bool, appIsActive: Bool, resumeScheduled: Bool) -> Bool {
        pausedForBackground && appIsActive && !resumeScheduled
    }

    /// A quality reconnect (heat, network), or a retry of one, runs only while the stream fills the screen in
    /// front of the player. In the background it would start a stream nobody watches; in the floating window
    /// it would close the window and cut the sound. It waits instead, and runs once the player is back.
    static func canReconnect(appIsActive: Bool, inPictureInPicture: Bool) -> Bool {
        appIsActive && !inPictureInPicture
    }

    /// Heat and data notices show only where they can be read; one that can't is skipped, not saved for later.
    static func canShowNotice(appIsActive: Bool, inPictureInPicture: Bool) -> Bool {
        appIsActive && !inPictureInPicture
    }

    /// What counts as "running" when the app leaves the screen. A refit that is reconnecting, or a failed one
    /// waiting to retry, counts too: leaving stops it (and coming back starts it), rather than a retry
    /// starting the stream later with nobody watching.
    static func isRunning(_ state: StreamState?, refitUnderway: Bool) -> Bool {
        switch state {
        case .launching?, .connecting?, .streaming?: true
        // Between the old stream's stop and the new one's start, or failed and waiting for a retry.
        default: refitUnderway
        }
    }
}

/// Keeps pause and resume in order. A stop runs at once (it interrupts a stream that is still connecting, so
/// Close or swipe-home never waits behind a slow handshake). A resume waits for every earlier stop to finish,
/// instead of being ignored, and only starts if the latest wish is still "running".
@MainActor final class StreamLifecycleQueue {
    private var tail: Task<Void, Never>?
    /// Resumes asked for and not yet finished.
    private(set) var pendingResumes = 0
    /// After the screen is left, no resume runs.
    private(set) var isClosed = false
    /// The latest wish: true after a resume, false after a pause or close.
    private(set) var wantsRunning = true

    func pause(_ stop: @escaping @MainActor () async -> Void) {
        wantsRunning = false
        let previous = tail
        let stopping = Task { await stop() }
        tail = Task {
            await previous?.value
            await stopping.value
        }
    }

    /// `shouldRun` is checked when the resume's turn comes (the app may have left again by then).
    func resume(shouldRun: @escaping @MainActor () -> Bool, _ start: @escaping @MainActor () async -> Void) {
        wantsRunning = true
        let previous = tail
        pendingResumes += 1
        tail = Task {
            await previous?.value
            if !isClosed, wantsRunning, shouldRun() { await start() }
            pendingResumes -= 1
        }
    }

    /// Leaving the screen: queued resumes become no-ops and the final stop runs at once.
    func close(finalStop stop: @escaping @MainActor () async -> Void) {
        isClosed = true
        pause(stop)
    }

    func waitUntilIdle() async { await tail?.value }
}
