import CoreGraphics
import Foundation
import Testing
@testable import PocketRig

@Suite struct StreamSizingTests {
    private let inner = CGSize(width: 669, height: 951)
    private let fold = CGRect(x: 0, y: 465, width: 669, height: 21)

    @Test func halfFoldedFillsTheTopHalfAt1080() {
        let size = StreamSizing.gamePixelSize(pose: .laptop, containerSize: inner, fold: fold, scale: 3, cap: .p1080)
        #expect(size == PixelSize(width: 1552, height: 1080))
    }

    @Test func sidewaysIsCappedAt1080Tall() {
        let size = StreamSizing.gamePixelSize(pose: .sideways, containerSize: CGSize(width: 951, height: 669),
                                              fold: nil, scale: 3, cap: .p1080)
        #expect(size == PixelSize(width: 1528, height: 1080))
    }

    @Test func uprightIsCappedAt1920Wide() {
        let size = StreamSizing.gamePixelSize(pose: .upright, containerSize: inner, fold: nil, scale: 3, cap: .p1080)
        #expect(size == PixelSize(width: 1920, height: 904))
    }

    @Test func bookIsTallerThanWide() {
        let size = StreamSizing.gamePixelSize(pose: .book, containerSize: CGSize(width: 951, height: 669),
                                              fold: CGRect(x: 465, y: 0, width: 21, height: 669), scale: 3, cap: .p1080)
        #expect(size == PixelSize(width: 1080, height: 1552))
    }

    @Test func coverScreenNeedsNoScalingDown() {
        let size = StreamSizing.gamePixelSize(pose: .cover, containerSize: CGSize(width: 466, height: 678),
                                              fold: nil, scale: 3, cap: .p1080)
        #expect(size == PixelSize(width: 1392, height: 672))
    }

    @Test func the720CapUsesLessData() {
        let size = StreamSizing.pixelSize(points: CGSize(width: 951, height: 669), scale: 3, cap: .p720)
        #expect(size == PixelSize(width: 1016, height: 720))
    }

    @Test func theHostsEncoderLimitWins() {
        let size = StreamSizing.pixelSize(points: CGSize(width: 1000, height: 1000), scale: 1, cap: .p1080, maxPixels: 500_000)
        #expect(size == PixelSize(width: 704, height: 704))
    }

    @Test func sidesAreMultiplesOf8AndNeverTiny() {
        #expect(StreamSizing.pixelSize(points: CGSize(width: 10, height: 10), scale: 1, cap: .p1080)
                == PixelSize(width: 64, height: 64))
        let odd = StreamSizing.pixelSize(points: CGSize(width: 333, height: 211), scale: 2, cap: .p1080)
        #expect(odd.width % 8 == 0 && odd.height % 8 == 0)
    }

    @Test func noAreaYetFallsBackToTheCap() {
        #expect(StreamSizing.pixelSize(points: .zero, scale: 3, cap: .p1080) == PixelSize(width: 1920, height: 1080))
    }

    @Test func serverReportsItsEncoderLimit() throws {
        let xml = #"<root status_code="200"><hostname>PC</hostname><MaxLumaPixelsHEVC>8912896</MaxLumaPixelsHEVC></root>"#
        let info = try ServerInfo(NvXML.parse(Data(xml.utf8)))
        #expect(info.maxLumaPixelsHEVC == 8_912_896)
        let bare = try ServerInfo(NvXML.parse(Data(#"<root status_code="200"><hostname>PC</hostname></root>"#.utf8)))
        #expect(bare.maxLumaPixelsHEVC == 0)
    }
}

@Suite struct ResizeDebouncerTests {
    private let start = ContinuousClock.now
    private let a = PixelSize(width: 1920, height: 904)
    private let b = PixelSize(width: 1552, height: 1080)

    @Test func ignoresSizesBeforeTheStreamStarts() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.propose(b, at: start)
        #expect(!debouncer.hasPending)
    }

    @Test func waitsForTheQuietPeriod() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.streamStarted(size: a)
        debouncer.propose(b, at: start)
        #expect(debouncer.takeDue(at: start + .milliseconds(300)) == nil)
        #expect(debouncer.takeDue(at: start + .milliseconds(700)) == b)
        #expect(debouncer.streaming == b)
        #expect(!debouncer.hasPending)
    }

    @Test func goingBackToTheStreamingSizeCancels() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.streamStarted(size: a)
        debouncer.propose(b, at: start)
        debouncer.propose(a, at: start + .milliseconds(200))
        #expect(debouncer.takeDue(at: start + .seconds(5)) == nil)
    }

    @Test func aNewSizeRestartsTheWait() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.streamStarted(size: a)
        let c = PixelSize(width: 1528, height: 1080)
        debouncer.propose(b, at: start)
        debouncer.propose(c, at: start + .milliseconds(600))
        #expect(debouncer.takeDue(at: start + .milliseconds(800)) == nil)
        #expect(debouncer.takeDue(at: start + .milliseconds(1300)) == c)
    }

    @Test func repeatingTheSameSizeKeepsTheOriginalClock() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.streamStarted(size: a)
        debouncer.propose(b, at: start)
        debouncer.propose(b, at: start + .milliseconds(500))
        #expect(debouncer.takeDue(at: start + .milliseconds(700)) == b)
    }

    @Test func aFailedReconnectRestoresTheOldSizeAndRetries() {
        var debouncer = ResizeDebouncer(quietPeriod: .milliseconds(700))
        debouncer.streamStarted(size: a)
        debouncer.propose(b, at: start)
        #expect(debouncer.takeDue(at: start + .seconds(1)) == b)
        #expect(debouncer.streaming == b)
        debouncer.streamFailed(at: start + .seconds(1))
        #expect(debouncer.streaming == a)
        #expect(debouncer.hasPending)
        #expect(debouncer.takeDue(at: start + .milliseconds(1500)) == nil)
        #expect(debouncer.takeDue(at: start + .milliseconds(1700)) == b)
    }
}
