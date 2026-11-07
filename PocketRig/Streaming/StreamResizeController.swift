import Foundation
import Observation

/// What the resize controller needs from a stream session. `StreamSession` is the real one.
@MainActor protocol ResizableSession: AnyObject {
    var state: StreamState { get }
    func beginReconnect()
    func reconnect(with settings: StreamSettings) async
    func start() async
    /// Stores the settings the next `start()` uses. Only for a stopped session.
    func updateSettings(_ settings: StreamSettings)
}

extension StreamSession: ResizableSession {}

/// Decides when the stream is refitted to a new game-area size, and what happens when the refit fails.
/// Stock Sunshine can't resize a running stream, so a refit is a stop and resume. A resume can fail
/// while the PC is still dropping the old connection, so a failed refit is retried a couple of times
/// (with a pause between) before the screen offers "Try again".
@MainActor @Observable final class StreamResizeController {
    static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    enum Reason: Equatable, Sendable {
        /// The game area changed size (fold, rotate).
        case resize
        /// Overheat protection or away-from-home quality.
        case quality
    }

    /// A refit (or a retry of one) is running; the screen shows "Fitting the picture…" instead of an error.
    private(set) var isRefitting = false
    /// A failed refit's retry is waiting for the player to come back (`canReconnect` said no).
    private(set) var isHoldingRetry = false
    /// Why the current (or last) refit runs, for the text over the picture.
    private(set) var reason: Reason = .resize
    /// A refit is running or a retry of one is waiting: the stream is between two connections.
    var hasUnfinishedRefit: Bool { isRefitting || isHoldingRetry }

    @ObservationIgnored private let session: any ResizableSession
    @ObservationIgnored private var debouncer: ResizeDebouncer
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let settingsFor: (PixelSize) -> StreamSettings
    @ObservationIgnored private let willReconnect: () -> Void
    @ObservationIgnored private let didReconnect: () -> Void
    /// Whether a reconnect may run now (the player is watching the full screen). Checked before every
    /// refit and every retry; while it says no, what is wanted stays pending until `resume()`.
    @ObservationIgnored private let canReconnect: @MainActor () -> Bool
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    @ObservationIgnored private var refitTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// The screen was left; nothing new starts after this.
    @ObservationIgnored private var isCancelled = false
    /// The quality rules changed (heat, network): refit once, even at the same size.
    @ObservationIgnored private var qualityDirty = false

    init(session: any ResizableSession, startSize: PixelSize,
         debouncer: ResizeDebouncer = ResizeDebouncer(),
         retryDelays: [Duration] = StreamResizeController.defaultRetryDelays,
         settingsFor: @escaping (PixelSize) -> StreamSettings,
         willReconnect: @escaping () -> Void = {}, didReconnect: @escaping () -> Void = {},
         canReconnect: @escaping @MainActor () -> Bool = { true }) {
        self.session = session
        self.debouncer = debouncer
        self.retryDelays = retryDelays
        self.settingsFor = settingsFor
        self.willReconnect = willReconnect
        self.didReconnect = didReconnect
        self.canReconnect = canReconnect
        self.debouncer.streamStarted(size: startSize)
    }

    private var isLive: Bool {
        switch session.state {
        case .launching, .connecting, .streaming: true
        default: false
        }
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    /// The wanted size changed (fold, rotate).
    func propose(_ size: PixelSize) {
        debouncer.propose(size, at: .now)
        schedule()
    }

    /// Overheat protection or away-from-home quality changed what the stream should use. Refits through
    /// the same stop-and-resume path as a resize, at `size` (which may be the current size).
    func qualityChanged(size: PixelSize) {
        qualityDirty = true
        debouncer.propose(size, at: .now)
        schedule()
    }

    /// The session's state changed; once streaming, catch up on any size wanted meanwhile.
    func sessionStateChanged(_ state: StreamState?) {
        if state == .streaming { schedule() }
    }

    /// The "Try again" button: resume after a stopped stream. The screen shows the normal "Starting…"
    /// progress for this, not the refit spinner; once streaming, `sessionStateChanged` catches up on size.
    func tryAgain() {
        guard !isCancelled, !isRefitting, isFailed else { return }
        isHoldingRetry = false
        resumeTask = Task { [session] in await session.start() }
    }

    /// The player is watching again (the app is back in front, or the floating window closed with it in front):
    /// run what waited. A held retry carries on; a size or quality change wanted meanwhile refits now.
    func resume() {
        guard !isCancelled, canReconnect() else { return }
        guard isHoldingRetry else { schedule(); return }
        isHoldingRetry = false
        guard isFailed, !isRefitting else { schedule(); return }
        isRefitting = true
        refitTask = Task { [weak self] in
            await self?.retryWhileFailed()
            self?.refitEnded()
        }
    }

    /// A stopped stream is about to start again (back from the background) at `size`. It starts with what is
    /// wanted now, so a quality or size change made while it was stopped needs no second reconnect.
    func streamWillRestart(at size: PixelSize) {
        // Only for a stopped stream: a second resume that arrives once it is already coming up must not wipe
        // a size or quality change made meanwhile.
        guard !isCancelled, !isLive else { return }
        waitTask?.cancel()
        debouncer.streamStarted(size: size)
        qualityDirty = false
        isHoldingRetry = false
        session.updateSettings(settingsFor(size))
    }

    /// Leaving the screen: stop waiting and retrying.
    func cancel() {
        isCancelled = true
        waitTask?.cancel()
        refitTask?.cancel()
        resumeTask?.cancel()
    }

    /// Waits out the quiet period, then refits at the wanted size (or at the same size for a quality change).
    private func schedule() {
        // A refit in progress picks up whatever is still wanted when it ends.
        guard !isRefitting, !isCancelled else { return }
        waitTask?.cancel()
        // Nobody watching: keep what is wanted pending; `resume()` schedules it again.
        guard debouncer.hasPending || qualityDirty, isLive, canReconnect() else { return }
        let wait = debouncer.quietPeriod
        waitTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled, !isCancelled, isLive, canReconnect() else { return }
            let size: PixelSize
            if let due = debouncer.takeDue(at: .now) {
                size = due
            } else if !debouncer.hasPending, qualityDirty, let current = debouncer.streaming {
                size = current
            } else {
                return
            }
            reason = qualityDirty ? .quality : .resize
            qualityDirty = false
            refit(with: settingsFor(size))
        }
    }

    /// Stop-and-resume at the new size; if the resume fails, retry `retryDelays.count` times.
    /// `session.start()` accepts a failed session and resumes the still-running game with the new
    /// settings, which the reconnect already stored.
    private func refit(with settings: StreamSettings) {
        isRefitting = true
        session.beginReconnect()   // first: the old stream's events stop reaching the screen
        willReconnect()
        refitTask = Task { [weak self, session] in
            await session.reconnect(with: settings)
            await self?.retryWhileFailed()
            self?.refitEnded()
        }
    }

    private func refitEnded() {
        isRefitting = false
        guard !isCancelled else { return }
        didReconnect()
        schedule()
    }

    /// A retry waits (`isHoldingRetry`) instead of starting a stream nobody is watching.
    private func retryWhileFailed() async {
        for delay in retryDelays {
            guard isFailed, !Task.isCancelled, !isCancelled else { return }
            try? await Task.sleep(for: delay)
            guard isFailed, !Task.isCancelled, !isCancelled else { return }
            guard canReconnect() else {
                isHoldingRetry = true
                return
            }
            await session.start()
        }
    }
}
