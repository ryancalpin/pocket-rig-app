import os

/// When one frame arrived and how long the PC spent on it, as moonlight reports in each decode unit.
struct FrameTiming: Equatable, Sendable {
    /// `LiGetMicroseconds()` time the frame's first packet arrived.
    var receiveUs: UInt64
    /// PC time (capture to send) in tenths of a millisecond; 0 when the PC doesn't report it.
    var hostLatencyTenthsMs: UInt16
}

/// One second of numbers. Nil until a full second has been measured.
struct FrameStats: Equatable, Sendable {
    var framesPerSecond: Double?
    /// Phone side: first packet in → frame handed to the screen.
    var phoneMs: Double?
    var pcMs: Double?
    /// True when frames stopped arriving, so the numbers above no longer describe the picture.
    var paused = false
}

/// Rolls frame timings into one-second windows. Written on moonlight's decoder thread, read on main.
final class FrameStatsRecorder: @unchecked Sendable {
    static let windowUs: UInt64 = 1_000_000
    /// No frame for this long means the picture has stalled.
    static let stallUs: UInt64 = 2_000_000

    private struct Window {
        var startUs: UInt64?
        var frames = 0
        var samples = 0
        var phoneTotalUs: UInt64 = 0
        var hostTotal: UInt64 = 0
        var hostSamples = 0
    }

    private struct State {
        var window = Window()
        var latest = FrameStats()
        var lastFrameUs: UInt64?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var latest: FrameStats { state.withLockUnchecked { $0.latest } }

    /// The latest numbers, or a paused result when no frame has arrived for about 2 s.
    func current(nowUs: UInt64) -> FrameStats {
        state.withLockUnchecked { s in
            if let last = s.lastFrameUs, nowUs > last, nowUs - last > Self.stallUs {
                return FrameStats(framesPerSecond: 0, phoneMs: nil, pcMs: nil, paused: true)
            }
            return s.latest
        }
    }

    func record(_ timing: FrameTiming, nowUs: UInt64) {
        state.withLockUnchecked { s in
            s.lastFrameUs = nowUs
            if s.window.startUs == nil {
                s.window.startUs = nowUs
            } else {
                s.window.frames += 1
            }
            s.window.samples += 1
            s.window.phoneTotalUs += nowUs >= timing.receiveUs ? nowUs - timing.receiveUs : 0
            if timing.hostLatencyTenthsMs > 0 {
                s.window.hostTotal += UInt64(timing.hostLatencyTenthsMs)
                s.window.hostSamples += 1
            }
            guard let start = s.window.startUs, nowUs - start >= Self.windowUs else { return }
            let w = s.window
            s.latest = FrameStats(
                framesPerSecond: Double(w.frames) * 1_000_000 / Double(nowUs - start),
                phoneMs: Double(w.phoneTotalUs) / Double(w.samples) / 1000,
                pcMs: w.hostSamples > 0 ? Double(w.hostTotal) / Double(w.hostSamples) / 10 : nil)
            s.window = Window(startUs: nowUs)
        }
    }

    func reset() {
        state.withLockUnchecked { $0 = State() }
    }
}
