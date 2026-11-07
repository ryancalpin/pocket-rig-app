import AVFoundation
import Foundation
import Testing
@testable import PocketRig

@Suite struct BassEnvelopeTests {
    private static let rate = 48_000.0
    private static let block = 240   // 5 ms, what Sunshine sends

    /// Feeds `blocks` blocks of a sine wave; returns every reported level. `rightSign` -1 makes the right
    /// channel the left one upside down, nil means mono.
    private static func feed(_ envelope: inout BassEnvelope, hz: Double, amplitude: Float, blocks: Int,
                             start: inout Int, rightSign: Float? = 1) -> [Float] {
        var reports: [Float] = []
        for _ in 0..<blocks {
            let left = (0..<block).map { i in
                amplitude * Float(sin(2 * Double.pi * hz * Double(start + i) / rate))
            }
            start += block
            let right = rightSign.map { sign in left.map { $0 * sign } }
            let report = left.withUnsafeBufferPointer { l in
                if let right {
                    return right.withUnsafeBufferPointer { r in envelope.process(left: l, right: r) }
                }
                return envelope.process(left: l, right: nil)
            }
            if let report { reports.append(report) }
        }
        return reports
    }

    @Test func loudBassIsFeltStrongly() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.5, blocks: 60, start: &t)
        #expect(e.level > 0.85)
    }

    @Test func highNotesAreNotFelt() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 2_000, amplitude: 0.5, blocks: 60, start: &t)
        #expect(e.level < 0.05)
    }

    @Test func quietBassIsFeltGently() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.05, blocks: 60, start: &t)
        #expect(e.level > 0.2)
        #expect(e.level < 0.6)
    }

    @Test func silenceIsNothing() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        let reports = Self.feed(&e, hz: 50, amplitude: 0, blocks: 20, start: &t)
        #expect(e.level == 0)
        #expect(reports.isEmpty)
    }

    @Test func theFeelingStopsWhenTheBassDoes() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.5, blocks: 60, start: &t)
        let reports = Self.feed(&e, hz: 50, amplitude: 0, blocks: 100, start: &t)
        #expect(e.level == 0)
        #expect(reports.last == 0)
    }

    @Test func aSteadySoundBarelyReports() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.05, blocks: 60, start: &t)
        let steady = Self.feed(&e, hz: 50, amplitude: 0.05, blocks: 50, start: &t)
        #expect(steady.count <= 1)   // at most one last nudge as it settles
    }

    @Test func monoWorks() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.5, blocks: 60, start: &t, rightSign: nil)
        #expect(e.level > 0.85)
    }

    @Test func oppositeChannelsCancel() {
        var e = BassEnvelope(sampleRate: Self.rate), t = 0
        _ = Self.feed(&e, hz: 50, amplitude: 0.5, blocks: 60, start: &t, rightSign: -1)
        #expect(e.level == 0)
    }

    @Test func theRendererHandsBackWhatItDecoded() throws {
        let packet = try OpusAudioRendererTests.encodePacket(frames: 240)
        let renderer = OpusAudioRenderer(samplesPerFrame: 240)
        _ = renderer.play(packet)   // the first packet only primes the decoder
        let pcm = try #require(renderer.play(packet))
        #expect(pcm.frameLength == 240)
        var envelope = BassEnvelope(sampleRate: pcm.format.sampleRate)
        _ = envelope.process(pcm)   // must not crash on real decoder output
    }
}
