/// Decides when a new game-area size is worth a reconnect. Stock Sunshine can't resize a running stream,
/// so each change costs a second or two of black screen: wait until the phone has held still for
/// `quietPeriod`, and skip it entirely if the size goes back to what is already streaming.
struct ResizeDebouncer: Sendable {
    static let defaultQuietPeriod: Duration = .milliseconds(700)

    let quietPeriod: Duration
    /// The size the current stream runs at. Nil before the first stream starts.
    private(set) var streaming: PixelSize?
    private var pending: PixelSize?
    private var pendingSince: ContinuousClock.Instant?
    /// What `takeDue` replaced, so a failed reconnect can be rolled back.
    private var lastTaken: (previous: PixelSize?, taken: PixelSize)?

    init(quietPeriod: Duration = ResizeDebouncer.defaultQuietPeriod) {
        self.quietPeriod = quietPeriod
    }

    var hasPending: Bool { pending != nil }

    mutating func streamStarted(size: PixelSize) {
        lastTaken = nil
        streaming = size
        pending = nil
        pendingSince = nil
    }

    /// Call whenever the wanted size changes.
    mutating func propose(_ size: PixelSize, at now: ContinuousClock.Instant) {
        guard let streaming else { return }
        if size == streaming {
            pending = nil
            pendingSince = nil
        } else if size != pending {
            pending = size
            pendingSince = now
        }
    }

    /// The size to reconnect at, once it has been wanted for the whole quiet period. Taking it marks it
    /// as the streaming size; call `streamFailed()` if the reconnect then fails.
    mutating func takeDue(at now: ContinuousClock.Instant) -> PixelSize? {
        guard let pending, let pendingSince, now - pendingSince >= quietPeriod else { return nil }
        let previous = streaming
        streamStarted(size: pending)
        lastTaken = (previous, pending)
        return pending
    }

    /// The caller must call this if the reconnect for the size `takeDue` returned did not succeed.
    /// It restores the previous streaming size and makes the size pending again, so it retries after
    /// a fresh quiet period.
    mutating func streamFailed(at now: ContinuousClock.Instant = .now) {
        guard let lastTaken, streaming == lastTaken.taken else { return }
        streaming = lastTaken.previous
        pending = lastTaken.taken
        pendingSince = now
        self.lastTaken = nil
    }
}
