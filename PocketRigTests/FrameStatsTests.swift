import Testing
@testable import PocketRig

@Suite struct FrameStatsTests {
    private let base: UInt64 = 10_000_000

    @Test func aFullSecondGivesFrameRatePhoneAndPCTime() {
        let recorder = FrameStatsRecorder()
        for i in 0...60 {
            let now = base + UInt64(i) * 16_667
            recorder.record(FrameTiming(receiveUs: now - 5_000, hostLatencyTenthsMs: 60), nowUs: now)
        }
        let stats = recorder.latest
        #expect(abs((stats.framesPerSecond ?? 0) - 60) < 0.1)
        #expect(abs((stats.phoneMs ?? 0) - 5) < 0.01)
        #expect(abs((stats.pcMs ?? 0) - 6) < 0.01)
    }

    @Test func nothingUntilASecondHasPassed() {
        let recorder = FrameStatsRecorder()
        recorder.record(FrameTiming(receiveUs: base, hostLatencyTenthsMs: 60), nowUs: base)
        recorder.record(FrameTiming(receiveUs: base, hostLatencyTenthsMs: 60), nowUs: base + 500_000)
        #expect(recorder.latest == FrameStats())
    }

    @Test func aPCThatDoesNotReportLeavesPCTimeEmpty() {
        let recorder = FrameStatsRecorder()
        recorder.record(FrameTiming(receiveUs: base, hostLatencyTenthsMs: 0), nowUs: base)
        recorder.record(FrameTiming(receiveUs: base + 1_000_000, hostLatencyTenthsMs: 0), nowUs: base + 1_000_000)
        #expect(recorder.latest.framesPerSecond == 1)
        #expect(recorder.latest.pcMs == nil)
    }

    @Test func clockSkewNeverGoesNegative() {
        let recorder = FrameStatsRecorder()
        recorder.record(FrameTiming(receiveUs: base + 50, hostLatencyTenthsMs: 0), nowUs: base)
        recorder.record(FrameTiming(receiveUs: base + 2_000_000, hostLatencyTenthsMs: 0), nowUs: base + 1_000_000)
        #expect(recorder.latest.phoneMs == 0)
    }

    @Test func resetClearsEverything() {
        let recorder = FrameStatsRecorder()
        recorder.record(FrameTiming(receiveUs: base, hostLatencyTenthsMs: 10), nowUs: base)
        recorder.record(FrameTiming(receiveUs: base, hostLatencyTenthsMs: 10), nowUs: base + 1_000_000)
        recorder.reset()
        #expect(recorder.latest == FrameStats())
    }

    @Test func stallReportsPausedAfterTwoSeconds() {
        let recorder = FrameStatsRecorder()
        for i in 0...60 {
            let now = base + UInt64(i) * 16_667
            recorder.record(FrameTiming(receiveUs: now, hostLatencyTenthsMs: 60), nowUs: now)
        }
        let last = base + 60 * 16_667
        #expect(recorder.current(nowUs: last + 1_000_000).paused == false)
        let stalled = recorder.current(nowUs: last + 2_500_000)
        #expect(stalled.paused)
        #expect(stalled.framesPerSecond == 0)
        #expect(stalled.phoneMs == nil)
        #expect(stalled.pcMs == nil)
    }

    @Test func noFramesYetIsNotPaused() {
        #expect(FrameStatsRecorder().current(nowUs: base) == FrameStats())
    }

    @Test func aSecondWindowReplacesTheFirst() {
        let recorder = FrameStatsRecorder()
        var now = base
        for _ in 0...30 {
            recorder.record(FrameTiming(receiveUs: now - 2_000, hostLatencyTenthsMs: 20), nowUs: now)
            now += 33_334
        }
        let first = recorder.latest
        for _ in 0...60 {
            recorder.record(FrameTiming(receiveUs: now - 8_000, hostLatencyTenthsMs: 40), nowUs: now)
            now += 16_667
        }
        let second = recorder.latest
        #expect(second != first)
        #expect(abs((second.framesPerSecond ?? 0) - 60) < 3)
        #expect(abs((second.phoneMs ?? 0) - 8) < 0.01)
        #expect(abs((second.pcMs ?? 0) - 4) < 0.01)
    }

    @Test func pausedTextIsHonest() {
        let paused = FrameStats(framesPerSecond: 0, phoneMs: nil, pcMs: nil, paused: true)
        #expect(StatsText.framesPerSecond(paused) == "Picture paused")
        #expect(StatsText.pcTime(paused) == "Picture paused")
        #expect(StatsText.milliseconds(nil, frames: paused) == "Picture paused")
    }
}
