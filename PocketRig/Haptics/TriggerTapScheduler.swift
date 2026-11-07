import Foundation

/// Turns trigger rumble into short, sharp taps: one the moment it starts, then more while it lasts,
/// closer together when it is stronger. The phone has one motor, so either trigger counts.
struct TriggerTapScheduler: Sendable {
    static let slowest: TimeInterval = 0.15
    static let fastest: TimeInterval = 0.05

    private(set) var level: Float = 0
    private var nextTap: TimeInterval?

    static func interval(for level: Float) -> TimeInterval {
        slowest - Double(min(max(level, 0), 1)) * (slowest - fastest)
    }

    /// When the next repeat tap is due, or nil when the triggers are still.
    var nextTapTime: TimeInterval? { level > 0 ? nextTap : nil }

    /// New trigger motor values. Returns a tap strength when one is due right now.
    mutating func update(left: UInt16, right: UInt16, at now: TimeInterval) -> Float? {
        let newLevel = max(FeelMixer.motorLevel(left), FeelMixer.motorLevel(right))
        let wasStill = level == 0
        level = newLevel
        guard newLevel > 0 else {
            nextTap = nil
            return nil
        }
        guard wasStill else { return nil }   // already tapping: keep the rhythm
        nextTap = now + Self.interval(for: newLevel)
        return newLevel
    }

    /// A repeat tap, if one is due.
    mutating func tick(at now: TimeInterval) -> Float? {
        guard level > 0, let due = nextTap, now >= due else { return nil }
        nextTap = now + Self.interval(for: level)
        return level
    }

    mutating func reset() {
        level = 0
        nextTap = nil
    }
}
