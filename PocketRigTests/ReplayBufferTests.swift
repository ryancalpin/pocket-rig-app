import CMoonlight
import CoreMedia
import Foundation
import Testing
@testable import PocketRig

@Suite struct ReplayBufferTests {
    static func makeFormat(width: Int32 = 1280, height: Int32 = 720) -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: width, height: height,
                                       extensions: nil, formatDescriptionOut: &format)
        return format!
    }

    private let format = ReplayBufferTests.makeFormat()
    /// 60 frames a second.
    private let frameUs: UInt64 = 16_667

    private func bytes(_ count: Int = 100) -> Data { Data(repeating: 0xAB, count: count) }

    /// Frames `0..<count`, a keyframe every `keyEvery`, each `size` bytes, 60 a second.
    private func feed(_ buffer: ReplayBuffer, count: Int, keyEvery: Int, size: Int = 100) {
        for index in 0..<count {
            buffer.append(bytes(size), isKeyframe: index % keyEvery == 0, ptsUs: UInt64(index) * frameUs, format: format)
        }
    }

    /// A non-key frame at `ptsUs`, reached in steps of at most one second.
    private func tick(_ buffer: ReplayBuffer, to ptsUs: UInt64) {
        var next = (buffer.clip()?.frames.last?.ptsUs ?? 0)
        while next + 1_000_000 < ptsUs {
            next += 1_000_000
            buffer.append(bytes(), isKeyframe: false, ptsUs: next, format: format)
        }
        buffer.append(bytes(), isKeyframe: false, ptsUs: ptsUs, format: format)
    }

    @Test func keepsThirtySecondsThatStartAtAKeyframe() throws {
        let buffer = ReplayBuffer()
        // 45 seconds with a keyframe every 10: the group from 0 s goes, the one from 10 s stays.
        feed(buffer, count: 2700, keyEvery: 600)
        #expect(buffer.keyframeCount == 4)
        let clip = try #require(buffer.clip())
        #expect(clip.frames.first?.isKeyframe == true)
        #expect(clip.frames.first?.ptsUs == 600 * frameUs)
        #expect(clip.frames.count == 2100)
        #expect(clip.endUs == 2700 * frameUs)
        #expect(clip.durationUs == 30_000_000)
        #expect(clip.seconds == 30)
    }

    @Test func aShortStreamSavesWhatItHas() throws {
        let buffer = ReplayBuffer()
        feed(buffer, count: 300, keyEvery: 600)   // 5 seconds, one keyframe
        let clip = try #require(buffer.clip())
        #expect(clip.startUs == 0)
        #expect(clip.seconds == 5)
        #expect(buffer.availableUs == 299 * frameUs)
    }

    @Test func framesBeforeTheFirstKeyframeAreDropped() {
        let buffer = ReplayBuffer()
        for index in 0..<5 {
            buffer.append(bytes(), isKeyframe: false, ptsUs: UInt64(index) * frameUs, format: format)
        }
        #expect(buffer.frameCount == 0)
        #expect(buffer.clip() == nil)
    }

    @Test func theMemoryCapDropsTheOldestGroup() throws {
        let buffer = ReplayBuffer(byteCap: 10_000)
        feed(buffer, count: 12, keyEvery: 4, size: 1000)
        #expect(buffer.keyframeCount == 2)
        #expect(buffer.byteCount == 8000)
        let clip = try #require(buffer.clip())
        #expect(clip.frames.first?.isKeyframe == true)
        #expect(clip.frames.first?.ptsUs == 4 * frameUs)
    }

    @Test func aGroupBiggerThanTheCapEmptiesTheBufferAndAsksForAKeyframe() {
        let buffer = ReplayBuffer(byteCap: 2_500)
        feed(buffer, count: 3, keyEvery: 100, size: 1000)
        #expect(buffer.frameCount == 0)
        #expect(buffer.byteCount == 0)
        #expect(buffer.clip() == nil)
        #expect(buffer.shouldRequestKeyframe())
    }

    @Test func timesAlwaysMoveForward() throws {
        let buffer = ReplayBuffer()
        buffer.append(bytes(), isKeyframe: true, ptsUs: 5_000, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 5_000, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 1_000, format: format)
        #expect(try #require(buffer.clip()).frames.map(\.ptsUs) == [5_000, 6_000, 7_000])
    }

    @Test func aGapDropsTheOpenGroupAndWaitsForTheNextKeyframe() throws {
        let buffer = ReplayBuffer()
        feed(buffer, count: 6, keyEvery: 3)           // two groups of 3
        buffer.noteGap()
        #expect(buffer.keyframeCount == 1)
        #expect(buffer.frameCount == 3)
        #expect(buffer.byteCount == 300)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 6 * frameUs, format: format)   // can't be decoded: ignored
        #expect(buffer.frameCount == 3)
        buffer.append(bytes(), isKeyframe: true, ptsUs: 7 * frameUs, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 8 * frameUs, format: format)
        #expect(buffer.keyframeCount == 2)
        #expect(buffer.frameCount == 5)
        #expect(try #require(buffer.clip()).frames.map(\.isKeyframe) == [true, false, false, true, false])
    }

    /// The renderer reports a gap for every frame it rejects. While the buffer already waits for a keyframe,
    /// more gaps must not throw away the older, complete groups.
    @Test func moreGapsWhileWaitingKeepTheCompleteGroups() throws {
        let buffer = ReplayBuffer()
        feed(buffer, count: 9, keyEvery: 3)           // three groups of 3
        buffer.noteGap()                              // the open (third) group goes
        buffer.noteGap()
        buffer.noteGap()
        #expect(buffer.keyframeCount == 2)
        #expect(buffer.frameCount == 6)
        #expect(buffer.byteCount == 600)
        #expect(try #require(buffer.clip()).frames.count == 6)
    }

    @Test func aGapAsksForAKeyframe() {
        let buffer = ReplayBuffer()
        feed(buffer, count: 3, keyEvery: 3)
        buffer.noteGap()
        #expect(buffer.shouldRequestKeyframe())
    }

    @Test func aTimeThatGoesBackStartsOver() throws {
        let buffer = ReplayBuffer()
        buffer.append(bytes(), isKeyframe: true, ptsUs: 100_000_000, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 100_016_667, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 1_000_000, format: format)   // clock restarted
        #expect(buffer.frameCount == 0)   // waits for a keyframe
        #expect(buffer.shouldRequestKeyframe())
        buffer.append(bytes(), isKeyframe: true, ptsUs: 1_016_667, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 1_033_334, format: format)
        #expect(try #require(buffer.clip()).frames.map(\.ptsUs) == [1_016_667, 1_033_334])
    }

    @Test func aBigJumpForwardStartsOver() throws {
        let buffer = ReplayBuffer()
        buffer.append(bytes(), isKeyframe: true, ptsUs: 0, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 16_667, format: format)
        buffer.append(bytes(), isKeyframe: true, ptsUs: 16_667 + 60_000_001, format: format)
        #expect(buffer.keyframeCount == 1)
        #expect(buffer.frameCount == 1)
        #expect(try #require(buffer.clip()).frames.first?.ptsUs == 60_016_668)
    }

    @Test func aStillPictureGapIsKept() {
        let buffer = ReplayBuffer()
        buffer.append(bytes(), isKeyframe: true, ptsUs: 0, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 20_000_000, format: format)
        #expect(buffer.frameCount == 2)
    }

    @Test func smallJitterIsNudgedForwardNotTreatedAsABreak() throws {
        let buffer = ReplayBuffer()
        buffer.append(bytes(), isKeyframe: true, ptsUs: 100_000, format: format)
        buffer.append(bytes(), isKeyframe: false, ptsUs: 95_000, format: format)   // 5 ms back
        #expect(try #require(buffer.clip()).frames.map(\.ptsUs) == [100_000, 101_000])
    }

    @Test func sharedByManyThreadsItStaysConsistent() {
        let buffer = ReplayBuffer(byteCap: 50_000)
        let format = self.format
        let frameUs = self.frameUs
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            if worker == 0 {
                for index in 0..<2000 {
                    buffer.append(Data(repeating: 1, count: 100), isKeyframe: index % 30 == 0,
                                  ptsUs: UInt64(index) * frameUs, format: format)
                    if index % 400 == 0 { buffer.noteGap() }
                }
            } else {
                for index in 0..<500 {
                    if let clip = buffer.clip() { #expect(clip.frames.first?.isKeyframe == true) }
                    _ = buffer.shouldRequestKeyframe()
                    _ = buffer.byteCount
                    if worker == 7, index % 100 == 0 { buffer.reset() }
                }
            }
        }
        #expect(buffer.byteCount <= 50_000)
        if let clip = buffer.clip() { #expect(clip.frames.first?.isKeyframe == true) }
    }

    @Test func aNewPictureFormatStartsOver() throws {
        let buffer = ReplayBuffer()
        feed(buffer, count: 3, keyEvery: 3)
        let smaller = Self.makeFormat(width: 640, height: 360)
        buffer.append(bytes(), isKeyframe: true, ptsUs: 10 * frameUs, format: smaller)
        #expect(buffer.keyframeCount == 1)
        #expect(buffer.frameCount == 1)
        let clip = try #require(buffer.clip())
        #expect(CMFormatDescriptionEqual(clip.format, otherFormatDescription: smaller))
    }

    @Test func asksForAKeyframeEveryTenSecondsAndRetriesAfterThree() {
        let buffer = ReplayBuffer()
        #expect(!buffer.shouldRequestKeyframe())   // nothing yet: the stream starts with a keyframe anyway
        buffer.append(bytes(), isKeyframe: true, ptsUs: 0, format: format)
        tick(buffer, to: 9_900_000)
        #expect(!buffer.shouldRequestKeyframe())
        tick(buffer, to: 10_000_000)
        #expect(buffer.shouldRequestKeyframe())
        tick(buffer, to: 11_000_000)
        #expect(!buffer.shouldRequestKeyframe())   // asked a second ago
        tick(buffer, to: 13_100_000)
        #expect(buffer.shouldRequestKeyframe())    // still no keyframe after 3 s: ask again
        buffer.append(bytes(), isKeyframe: true, ptsUs: 13_500_000, format: format)
        tick(buffer, to: 20_000_000)
        #expect(!buffer.shouldRequestKeyframe())
        tick(buffer, to: 23_600_000)
        #expect(buffer.shouldRequestKeyframe())
    }

    @Test func resetForgetsEverything() {
        let buffer = ReplayBuffer()
        feed(buffer, count: 10, keyEvery: 5)
        buffer.reset()
        #expect(buffer.frameCount == 0)
        #expect(buffer.byteCount == 0)
        #expect(buffer.clip() == nil)
        #expect(!buffer.shouldRequestKeyframe())
    }
}

@Suite @MainActor struct VideoRendererReplayTests {
    private let startCode = Data([0, 0, 0, 1])
    private var idr: [(type: Int32, data: Data)] {
        [(BUFFER_TYPE_SPS, startCode + Fixtures.sps),
         (BUFFER_TYPE_PPS, startCode + Fixtures.pps),
         (BUFFER_TYPE_PICDATA, startCode + Data([0x65, 0x88, 0x84]))]
    }
    private var pFrame: [(type: Int32, data: Data)] { [(BUFFER_TYPE_PICDATA, startCode + Data([0x41, 0x9A, 0x00]))] }

    @Test func acceptedFramesGoIntoTheReplayBuffer() throws {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        #expect(renderer.submit(units: idr, isIDR: true, ptsUs: 0) == DR_OK)
        #expect(renderer.submit(units: pFrame, isIDR: false, ptsUs: 16_667) == DR_OK)
        #expect(renderer.replay.frameCount == 2)
        #expect(renderer.replay.keyframeCount == 1)
        let clip = try #require(renderer.replay.clip())
        #expect(clip.frames.map(\.ptsUs) == [0, 16_667])
        #expect(clip.frames.first?.isKeyframe == true)
        #expect(clip.frames.first?.data == NALUnitParser.lengthPrefixed([Data([0x65, 0x88, 0x84])]))
    }

    @Test func aRejectedFrameIsNotKept() {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        #expect(renderer.submit(units: pFrame, isIDR: false, ptsUs: 0) == DR_NEED_IDR)
        #expect(renderer.replay.frameCount == 0)
    }

    @Test func aRejectedFrameLeavesNoUndecodableStretch() {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        _ = renderer.submit(units: idr, isIDR: true, ptsUs: 0)
        _ = renderer.submit(units: pFrame, isIDR: false, ptsUs: 16_667)
        _ = renderer.submit(units: idr, isIDR: true, ptsUs: 33_334)
        _ = renderer.submit(units: pFrame, isIDR: false, ptsUs: 50_001)
        #expect(renderer.replay.frameCount == 4)
        #expect(renderer.submit(units: [], isIDR: false, ptsUs: 66_668) == DR_NEED_IDR)   // nothing to show
        #expect(renderer.replay.frameCount == 2)   // the open group went
        #expect(renderer.submit(units: pFrame, isIDR: false, ptsUs: 83_335) == DR_OK)
        #expect(renderer.replay.frameCount == 2)   // not kept: its start is gone
        #expect(renderer.submit(units: idr, isIDR: true, ptsUs: 100_002) == DR_OK)
        #expect(renderer.replay.frameCount == 3)
    }

    @Test func aNewConnectionOrAStopStartsAFreshClip() {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        _ = renderer.submit(units: idr, isIDR: true, ptsUs: 0)
        renderer.setup(codec: .h264)
        #expect(renderer.replay.frameCount == 0)
        _ = renderer.submit(units: idr, isIDR: true, ptsUs: 0)
        renderer.reset()
        #expect(renderer.replay.frameCount == 0)
    }
}
