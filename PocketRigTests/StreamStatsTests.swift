import Testing
@testable import PocketRig

@Suite struct StreamStatsTests {
    @Test func totalAddsPCNetworkAndPhone() {
        let snapshot = StatsSnapshot(rttMs: 18, rttVarianceMs: 2,
                                     frames: FrameStats(framesPerSecond: 60, phoneMs: 9, pcMs: 6), quality: .good)
        #expect(snapshot.totalMs == 33)
    }

    @Test func totalWithoutPCTimeStillShows() {
        let snapshot = StatsSnapshot(rttMs: 18, rttVarianceMs: nil,
                                     frames: FrameStats(framesPerSecond: 60, phoneMs: 9, pcMs: nil), quality: .good)
        #expect(snapshot.totalMs == 27)
    }

    @Test func totalNeedsNetworkAndPhone() {
        let snapshot = StatsSnapshot(rttMs: nil, rttVarianceMs: nil, frames: FrameStats(), quality: .unknown)
        #expect(snapshot.totalMs == nil)
    }

    @Test func textsArePlain() {
        #expect(StatsText.milliseconds(12.4) == "12 ms")
        #expect(StatsText.milliseconds(nil) == "Not available yet")
        #expect(StatsText.framesPerSecond(59.7) == "60 fps")
        #expect(StatsText.pcTime(FrameStats()) == "Not available yet")
        #expect(StatsText.pcTime(FrameStats(framesPerSecond: 60, phoneMs: 9, pcMs: nil)) == "Your PC doesn't report this")
        #expect(StatsText.pcTime(FrameStats(framesPerSecond: 60, phoneMs: 9, pcMs: 6)) == "6 ms")
    }

    @Test func connectionQualityReadsPlainly() {
        #expect(ConnectionQuality.unknown.title == "Checking…")
        #expect(ConnectionQuality.good.title == "Good")
        #expect(ConnectionQuality.poor.title == "Poor · try a lower quality")
    }
}
