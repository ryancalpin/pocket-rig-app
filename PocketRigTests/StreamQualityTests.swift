import Foundation
import Testing
@testable import PocketRig

@Suite struct HeatGovernorTests {
    private let t0 = ContinuousClock.now
    private func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    @Test func seriousLowersOneStep() {
        var governor = HeatGovernor()
        #expect(governor.update(.serious, enabled: true, now: at(0)) == .warm)
        #expect(governor.step == .warm)
    }

    @Test func criticalGoesStraightToHotEvenRightAfterAChange() {
        var governor = HeatGovernor()
        _ = governor.update(.serious, enabled: true, now: at(0))
        #expect(governor.update(.critical, enabled: true, now: at(10)) == .hot)
    }

    @Test func seriousWhileWarmHolds() {
        var governor = HeatGovernor()
        _ = governor.update(.serious, enabled: true, now: at(0))
        #expect(governor.update(.serious, enabled: true, now: at(400)) == nil)
        #expect(governor.step == .warm)
    }

    @Test func comingBackNeedsFiveCoolMinutes() {
        var governor = HeatGovernor()
        _ = governor.update(.serious, enabled: true, now: at(0))
        #expect(governor.update(.nominal, enabled: true, now: at(10)) == nil)   // the cool-down starts
        #expect(governor.update(.fair, enabled: true, now: at(200)) == nil)
        #expect(governor.update(.nominal, enabled: true, now: at(310)) == .normal)
    }

    @Test func comesBackOneStepAtATime() {
        var governor = HeatGovernor()
        _ = governor.update(.critical, enabled: true, now: at(0))
        #expect(governor.update(.fair, enabled: true, now: at(1)) == nil)
        #expect(governor.update(.fair, enabled: true, now: at(301)) == .warm)
        #expect(governor.update(.fair, enabled: true, now: at(400)) == nil)
        #expect(governor.update(.fair, enabled: true, now: at(601)) == .normal)
    }

    @Test func aHotSpellRestartsTheCoolDown() {
        var governor = HeatGovernor()
        _ = governor.update(.serious, enabled: true, now: at(0))
        _ = governor.update(.nominal, enabled: true, now: at(10))
        #expect(governor.update(.serious, enabled: true, now: at(200)) == nil)
        #expect(governor.update(.nominal, enabled: true, now: at(250)) == nil)
        #expect(governor.update(.nominal, enabled: true, now: at(500)) == nil)
        #expect(governor.update(.nominal, enabled: true, now: at(550)) == .normal)
    }

    @Test func neverChangesTwiceWithinThreeMinutesUnlessCritical() {
        var governor = HeatGovernor()
        _ = governor.update(.serious, enabled: true, now: at(0))
        _ = governor.update(.nominal, enabled: true, now: at(1))
        #expect(governor.update(.nominal, enabled: true, now: at(301)) == .normal)
        #expect(governor.update(.serious, enabled: true, now: at(350)) == nil)   // 49 s after the last change
        #expect(governor.update(.serious, enabled: true, now: at(482)) == .warm)
    }

    @Test func turningItOffPutsQualityBackAtOnce() {
        var governor = HeatGovernor()
        _ = governor.update(.critical, enabled: true, now: at(0))
        #expect(governor.update(.critical, enabled: false, now: at(1)) == .normal)
        #expect(governor.update(.critical, enabled: false, now: at(2)) == nil)
        #expect(governor.step == .normal)
    }

    @Test func aCoolPhoneDoesNothing() {
        var governor = HeatGovernor()
        #expect(governor.update(.nominal, enabled: true, now: at(0)) == nil)
        #expect(governor.update(.fair, enabled: true, now: at(1000)) == nil)
        #expect(governor.step == .normal)
    }

    @Test func noticesArePlain() {
        #expect(HeatStep.notice(from: .normal, to: .warm) == "Your phone is getting warm, so the picture is a little softer for now.")
        #expect(HeatStep.notice(from: .warm, to: .hot) == "Your phone is hot. Quality is lower until it cools down.")
        #expect(HeatStep.notice(from: .hot, to: .warm) == "Your phone is cooling down. Quality is going back up a step.")
        #expect(HeatStep.notice(from: .warm, to: .normal) == "Your phone has cooled down. Quality is back to normal.")
        #expect(HeatStep.notice(from: .warm, to: .warm) == nil)
    }
}

@Suite struct StreamQualityRulesTests {
    private func settings(fps: Int, kbps: Int) -> StreamSettings {
        var s = StreamSettings.default
        s.fps = fps
        s.bitrateKbps = kbps
        return s
    }

    @Test func aWarmOrHotPhoneStreamsAt720p() {
        #expect(StreamQualityRules.cap(.p1080, heat: .normal) == .p1080)
        #expect(StreamQualityRules.cap(.p1080, heat: .warm) == .p720)
        #expect(StreamQualityRules.cap(.p1080, heat: .hot) == .p720)
        #expect(StreamQualityRules.cap(.p720, heat: .normal) == .p720)
    }

    @Test func heatLowersFrameRateAndData() {
        let best = settings(fps: 120, kbps: 50_000)
        let warm = StreamQualityRules.adjust(best, for: QualityContext(heat: .warm))
        #expect(warm.fps == 60 && warm.bitrateKbps == 15_000)
        let hot = StreamQualityRules.adjust(best, for: QualityContext(heat: .hot))
        #expect(hot.fps == 30 && hot.bitrateKbps == 8_000)
        #expect(StreamQualityRules.adjust(best, for: QualityContext()) == best)
    }

    @Test func neverRaisesAnything() {
        let low = settings(fps: 30, kbps: 5_000)
        #expect(StreamQualityRules.adjust(low, for: QualityContext(heat: .hot, awayLimitKbps: 10_000)) == low)
    }

    @Test func aZeroOrNegativeAwayLimitIsIgnored() {
        let balanced = settings(fps: 60, kbps: 20_000)
        #expect(StreamQualityRules.adjust(balanced, for: QualityContext(awayLimitKbps: 0)) == balanced)
        #expect(StreamQualityRules.adjust(balanced, for: QualityContext(awayLimitKbps: -5)) == balanced)
    }

    @Test func awayFromHomeCapsTheData() {
        let balanced = settings(fps: 60, kbps: 20_000)
        #expect(StreamQualityRules.adjust(balanced, for: QualityContext(awayLimitKbps: 10_000)).bitrateKbps == 10_000)
        #expect(StreamQualityRules.adjust(balanced, for: QualityContext(heat: .hot, awayLimitKbps: 10_000)).bitrateKbps == 8_000)
    }

    @Test func awayMeansMobileDataLowDataModeOrTailscale() {
        #expect(StreamQualityRules.isAway(network: NetworkSnapshot(isExpensive: true), streamAddress: "192.168.1.50"))
        #expect(StreamQualityRules.isAway(network: NetworkSnapshot(isConstrained: true), streamAddress: nil))
        #expect(StreamQualityRules.isAway(network: .home, streamAddress: "100.101.102.103"))
        #expect(!StreamQualityRules.isAway(network: .home, streamAddress: "192.168.1.50"))
        #expect(!StreamQualityRules.isAway(network: .home, streamAddress: nil))
    }

    @Test func sameAsAtHomeMeansNoLimit() {
        let cellular = NetworkSnapshot(isExpensive: true)
        #expect(StreamQualityRules.awayLimit(network: cellular, streamAddress: nil, preference: 5_000) == 5_000)
        #expect(StreamQualityRules.awayLimit(network: cellular, streamAddress: nil, preference: 0) == nil)
        #expect(StreamQualityRules.awayLimit(network: .home, streamAddress: "192.168.1.50", preference: 5_000) == nil)
    }
}

@Suite struct DataUseTests {
    @Test func megabitsBecomeGigabytesAnHour() {
        #expect(DataUse.gigabytesPerHour(kbps: 10_000) == 4.5)
        #expect(DataUse.gigabytesPerHour(kbps: 20_000) == 9)
    }

    @Test func theWordingIsShortAndRounded() {
        #expect(DataUse.perHourText(kbps: 10_000) == "about 4.5 GB an hour")
        #expect(DataUse.perHourText(kbps: 20_000) == "about 9 GB an hour")
        #expect(DataUse.perHourText(kbps: 50_000) == "about 23 GB an hour")
        #expect(DataUse.warning(kbps: 10_000) == "You're on mobile data. At this quality, streaming uses about 4.5 GB an hour.")
    }
}
