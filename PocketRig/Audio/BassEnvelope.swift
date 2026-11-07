import AVFoundation

/// How much bass is in the game audio right now, 0…1, for "feel the sound". Keeps only the low end
/// (below about 120 Hz), follows its loudness, rises at once and fades over about a seventh of a second.
/// Pure: feed it audio, read `level`. Runs on the audio thread, so it never allocates or locks.
struct BassEnvelope: Sendable {
    static let cutoffHz = 120.0
    /// How long the loudness follower averages over.
    static let smoothingSeconds = 0.02
    /// Bass quieter than this isn't felt; louder than `ceilingDB` is felt at full strength.
    static let floorDB: Float = -42
    static let ceilingDB: Float = -12
    /// Each block keeps this share of the previous level when the bass gets quieter.
    static let release: Float = 0.85
    /// Smaller changes aren't reported, so a steady sound doesn't flood the main thread.
    static let minimumChange: Float = 0.04

    private let alpha: Float
    private let beta: Float
    private var stage1: Float = 0
    private var stage2: Float = 0
    private var meanSquare: Float = 0
    private var lastReported: Float = 0
    private(set) var level: Float = 0

    init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        alpha = Float(1 - exp(-2 * Double.pi * Self.cutoffHz / rate))
        beta = Float(1 - exp(-1 / (rate * Self.smoothingSeconds)))
    }

    /// One block of samples; `right` is nil for mono. Returns a level to report, or nil if it barely moved.
    mutating func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?) -> Float? {
        guard !left.isEmpty else { return nil }
        for i in 0..<left.count {
            var x = left[i]
            if let right, i < right.count { x = (x + right[i]) * 0.5 }
            guard x.isFinite else { continue }
            // Two gentle low-pass stages keep the bass and drop everything above it.
            stage1 += alpha * (x - stage1)
            stage2 += alpha * (stage1 - stage2)
            meanSquare += beta * (stage2 * stage2 - meanSquare)
        }
        let rms = meanSquare.squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -Float.infinity
        let target = min(max((db - Self.floorDB) / (Self.ceilingDB - Self.floorDB), 0), 1)
        var next = max(target, level * Self.release)
        if next < 0.01 { next = 0 }
        level = next
        let changed = abs(next - lastReported) >= Self.minimumChange || (next == 0 && lastReported != 0)
        guard changed else { return nil }
        lastReported = next
        return next
    }

    /// A decoded block (non-interleaved float, as `OpusAudioRenderer` produces).
    mutating func process(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        let left = UnsafeBufferPointer(start: channels[0], count: count)
        let right = buffer.format.channelCount > 1 ? UnsafeBufferPointer(start: channels[1], count: count) : nil
        return process(left: left, right: right)
    }
}
