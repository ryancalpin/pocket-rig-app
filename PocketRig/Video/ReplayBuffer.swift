import CoreMedia
import Foundation

/// One compressed video frame as it arrived from the PC: length-prefixed NAL units, ready for a movie file.
struct ReplayFrame: Sendable, Equatable {
    let data: Data
    let isKeyframe: Bool
    /// The stream's own clock, in microseconds. Strictly increasing inside one buffer.
    let ptsUs: UInt64
}

/// The frames for "Save last 30 seconds". They start at a keyframe, so the movie can be decoded from its
/// first frame. The movie itself begins at `startUs`: frames before it only lead up to that point.
/// `@unchecked Sendable`: a format description never changes once made.
struct ReplayClip: @unchecked Sendable {
    let format: CMVideoFormatDescription
    let frames: [ReplayFrame]
    let startUs: UInt64
    let endUs: UInt64

    var durationUs: UInt64 { endUs - startUs }
    /// Whole seconds, at least 1, for "Saved the last N seconds".
    var seconds: Int { max(1, Int((Double(durationUs) / 1_000_000).rounded())) }
}

/// The last ~30 seconds of the stream, still compressed, for instant replay. Sunshine sends a keyframe
/// only when asked, so the stream asks about every 10 seconds (`shouldRequestKeyframe`). Frames are kept
/// in groups that each start with a keyframe. The oldest group goes once the newer ones still cover 30
/// seconds, or when the memory cap is reached. Fed on moonlight's video thread, read on the main thread.
final class ReplayBuffer: @unchecked Sendable {
    static let defaultClipUs: UInt64 = 30_000_000
    /// 160 MiB: about 40 s at 20 Mbps (Balanced), about 25 s at 50 Mbps (Best).
    static let defaultByteCap = 160 * 1024 * 1024
    /// Ask for a keyframe once the newest is this old (stream clock)…
    static let keyframeIntervalUs: UInt64 = 10_000_000
    /// …and no more often than this while waiting for it.
    static let keyframeRetryUs: UInt64 = 3_000_000

    let clipUs: UInt64
    let byteCap: Int

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var groups: [[ReplayFrame]] = []
    private var bytes = 0
    private var newestPtsUs: UInt64?
    private var lastKeyframePtsUs: UInt64?
    private var lastRequestPtsUs: UInt64?
    /// One group outgrew the cap and everything was dropped; a keyframe is needed to start again.
    private var needsKeyframe = false
    /// A gap or clock break happened: frames are ignored until the next keyframe.
    private var waitingForKeyframe = false

    init(clipUs: UInt64 = ReplayBuffer.defaultClipUs, byteCap: Int = ReplayBuffer.defaultByteCap) {
        self.clipUs = clipUs
        self.byteCap = byteCap
    }

    /// How far back a time may slip and still count as jitter (it is nudged forward instead).
    static let jitterToleranceUs: UInt64 = 10_000
    /// A forward jump bigger than this is a break in the stream clock. Smaller gaps are real time
    /// (Sunshine sends no frames while the picture is still), and the 30 s window trims them normally.
    static let maxForwardJumpUs: UInt64 = 60_000_000

    func append(_ data: Data, isKeyframe: Bool, ptsUs: UInt64, format newFormat: CMVideoFormatDescription) {
        // Dropped groups are freed after the lock is released, so a big free never blocks the video thread.
        var dropped: [[ReplayFrame]] = []
        lock.lock()
        appendLocked(data, isKeyframe: isKeyframe, ptsUs: ptsUs, format: newFormat, dropped: &dropped)
        lock.unlock()
    }

    private func appendLocked(_ data: Data, isKeyframe: Bool, ptsUs: UInt64,
                              format newFormat: CMVideoFormatDescription, dropped: inout [[ReplayFrame]]) {
        // A new picture size or codec can't share a movie with the old one.
        if let format, format !== newFormat, !CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) {
            dropped += clearLocked()
        }
        format = newFormat
        var pts = ptsUs
        if let newest = newestPtsUs {
            if ptsUs <= newest {
                if newest - ptsUs <= Self.jitterToleranceUs {
                    pts = newest + 1_000   // a movie needs strictly increasing times
                } else {
                    dropped += discontinuityLocked(newFormat)
                }
            } else if ptsUs - newest > Self.maxForwardJumpUs {
                dropped += discontinuityLocked(newFormat)
            }
        }
        newestPtsUs = pts
        if isKeyframe {
            groups.append([])
            lastKeyframePtsUs = pts
            needsKeyframe = false
            waitingForKeyframe = false
        } else if groups.isEmpty || waitingForKeyframe {
            return   // nothing to decode it from
        }
        groups[groups.count - 1].append(ReplayFrame(data: data, isKeyframe: isKeyframe, ptsUs: pts))
        bytes += data.count
        // The second group alone already covers the clip: the first isn't needed.
        while groups.count >= 2, groups[1][0].ptsUs + clipUs <= pts { dropped.append(dropOldestLocked()) }
        while bytes > byteCap, groups.count >= 2 { dropped.append(dropOldestLocked()) }
        if bytes > byteCap {
            dropped += groups
            groups = []
            bytes = 0
            needsKeyframe = true
        }
    }

    /// The stream clock broke: start fresh at the next keyframe, and ask for one.
    private func discontinuityLocked(_ newFormat: CMVideoFormatDescription) -> [[ReplayFrame]] {
        let old = clearLocked()
        format = newFormat
        needsKeyframe = true
        waitingForKeyframe = true
        return old
    }

    /// A frame was lost or rejected after the last one kept. The newest group can't be decoded to its end,
    /// so drop it and ignore frames until the next keyframe. Once already waiting, the open group is gone
    /// and the ones left are complete, so a further gap keeps them.
    func noteGap() {
        var dropped: [[ReplayFrame]] = []
        lock.lock()
        if !waitingForKeyframe, !groups.isEmpty {
            let open = groups.removeLast()
            bytes -= open.reduce(0) { $0 + $1.data.count }
            dropped.append(open)
        }
        waitingForKeyframe = true
        needsKeyframe = true
        lock.unlock()
        _ = dropped   // freed here, outside the lock
    }

    /// True when the stream should ask the PC for a keyframe now. Each true counts as a request.
    func shouldRequestKeyframe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = newestPtsUs else { return false }
        let due = needsKeyframe || lastKeyframePtsUs.map { newest >= $0 + Self.keyframeIntervalUs } ?? true
        guard due else { return false }
        if let last = lastRequestPtsUs, newest < last + Self.keyframeRetryUs { return false }
        lastRequestPtsUs = newest
        return true
    }

    /// The frames to save, or nil when there are none.
    func clip() -> ReplayClip? {
        lock.lock()
        defer { lock.unlock() }
        let frames = groups.flatMap { $0 }
        guard let format, let first = frames.first, let last = frames.last else { return nil }
        // The last frame lasts as long as the one before it (between 1 and 100 ms), or 1/60 s.
        var lastDuration: UInt64 = 16_667
        if frames.count >= 2 { lastDuration = min(100_000, max(1_000, last.ptsUs - frames[frames.count - 2].ptsUs)) }
        let end = last.ptsUs + lastDuration
        let start = end > clipUs ? max(first.ptsUs, end - clipUs) : first.ptsUs
        return ReplayClip(format: format, frames: frames, startUs: start, endUs: end)
    }

    /// From the first kept frame to the newest.
    var availableUs: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let first = groups.first?.first, let last = groups.last?.last else { return 0 }
        return last.ptsUs - first.ptsUs
    }

    var keyframeCount: Int { lock.withLock { groups.count } }
    var frameCount: Int { lock.withLock { groups.reduce(0) { $0 + $1.count } } }
    var byteCount: Int { lock.withLock { bytes } }

    func reset() {
        lock.lock()
        let old = clearLocked()
        lock.unlock()
        _ = old   // freed here, outside the lock
    }

    private func dropOldestLocked() -> [ReplayFrame] {
        let oldest = groups.removeFirst()
        bytes -= oldest.reduce(0) { $0 + $1.data.count }
        return oldest
    }

    private func clearLocked() -> [[ReplayFrame]] {
        let old = groups
        format = nil
        groups = []
        waitingForKeyframe = false
        bytes = 0
        newestPtsUs = nil
        lastKeyframePtsUs = nil
        lastRequestPtsUs = nil
        needsKeyframe = false
        return old
    }
}
