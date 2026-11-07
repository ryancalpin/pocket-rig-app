/// How moonlight rates the connection (`connectionStatusUpdate`).
enum ConnectionQuality: Equatable, Sendable {
    case unknown, good, poor

    var title: String {
        switch self {
        case .unknown: "Checking…"
        case .good: "Good"
        case .poor: "Poor · try a lower quality"
        }
    }

    var symbol: String {
        self == .poor ? "wifi.exclamationmark" : "wifi"
    }
}

/// Everything the Stats tab shows, read once a second.
struct StatsSnapshot: Equatable, Sendable {
    var rttMs: Double?
    var rttVarianceMs: Double?
    var frames: FrameStats
    var quality: ConnectionQuality

    /// PC + network round trip + phone. PC time counts as zero when the PC doesn't report it.
    var totalMs: Double? {
        guard let rttMs, let phone = frames.phoneMs else { return nil }
        return rttMs + phone + (frames.pcMs ?? 0)
    }

    #if DEBUG
    static let demo = StatsSnapshot(rttMs: 18, rttVarianceMs: 2,
                                    frames: FrameStats(framesPerSecond: 60, phoneMs: 9, pcMs: 6), quality: .good)
    #endif
}

enum StatsText {
    static let notYet = "Not available yet"

    static func milliseconds(_ value: Double?, frames: FrameStats) -> String {
        frames.paused ? paused : milliseconds(value)
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? notYet
    }

    static let paused = "Picture paused"

    static func framesPerSecond(_ frames: FrameStats) -> String {
        frames.paused ? paused : framesPerSecond(frames.framesPerSecond)
    }

    static func framesPerSecond(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) fps" } ?? notYet
    }

    static func pcTime(_ frames: FrameStats) -> String {
        if frames.paused { return paused }
        if let pc = frames.pcMs { return milliseconds(pc) }
        return frames.framesPerSecond == nil ? notYet : "Your PC doesn't report this"
    }
}
