import Testing
@testable import PocketRig

@Suite @MainActor struct StreamBannerTests {
    @Test func heatBannersUseTheNoticeAndAThermometer() {
        let warm = StreamBanner.heat(from: .normal, to: .warm)
        #expect(warm?.message == HeatStep.notice(from: .normal, to: .warm))
        #expect(warm?.symbol == "thermometer.high")
        #expect(StreamBanner.heat(from: .warm, to: .normal)?.symbol == "thermometer.medium")
        #expect(StreamBanner.heat(from: .hot, to: .hot) == nil)
    }

    @Test func theDataWarningSaysHowMuchAnHour() {
        let banner = StreamBanner.dataWarning(kbps: 10_000)
        #expect(banner.message == DataUse.warning(kbps: 10_000))
        #expect(banner.symbol == "antenna.radiowaves.left.and.right")
    }

    @Test func aBannerGoesAwayOnItsOwn() async {
        let model = StreamBannerModel()
        model.show(StreamBanner.dataWarning(kbps: 10_000), for: .milliseconds(20))
        #expect(model.current != nil)
        for _ in 0..<100 where model.current != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.current == nil)
    }

    @Test func aNewBannerReplacesTheOldOneAndClearWorks() {
        let model = StreamBannerModel()
        model.show(StreamBanner.dataWarning(kbps: 10_000))
        let heat = StreamBanner.heat(from: .normal, to: .hot)!
        model.show(heat)
        #expect(model.current == heat)
        model.clear()
        #expect(model.current == nil)
    }

    @Test func aWaitingBannerShowsAfterTheCurrentOne() async {
        let model = StreamBannerModel()
        let heat = StreamBanner.heat(from: .normal, to: .hot)!
        let data = StreamBanner.dataWarning(kbps: 10_000)
        model.show(heat, for: .milliseconds(20))
        model.showAfterCurrent(data, for: .milliseconds(20))
        #expect(model.current == heat)
        for _ in 0..<100 where model.current == heat { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.current == data)
        for _ in 0..<100 where model.current != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.current == nil)
    }

    @Test func clearDropsWaitingBanners() async {
        let model = StreamBannerModel()
        model.show(StreamBanner.heat(from: .normal, to: .hot)!, for: .milliseconds(20))
        model.showAfterCurrent(StreamBanner.dataWarning(kbps: 10_000), for: .milliseconds(20))
        model.clear()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.current == nil)
    }

    @Test func aWaitingBannerShowsAtOnceWhenNothingIsShowing() {
        let model = StreamBannerModel()
        let data = StreamBanner.dataWarning(kbps: 10_000)
        model.showAfterCurrent(data)
        #expect(model.current == data)
        model.clear()
    }
}
