import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import PocketRig

/// Stands in for Photos: says yes or no, and checks the movie it is handed.
final class FakeVideoSaver: VideoSaving, @unchecked Sendable {
    let allowed: Bool
    var failure: Error?
    private let lock = NSLock()
    private var _durations: [Double] = []
    private var _urls: [URL] = []

    init(allowed: Bool) { self.allowed = allowed }

    func requestAccess() async -> Bool { allowed }

    func saveVideo(at url: URL) async throws {
        if let failure { throw failure }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        lock.withLock {
            _durations.append(duration)
            _urls.append(url)
        }
    }

    var durations: [Double] { lock.withLock { _durations } }
    var urls: [URL] { lock.withLock { _urls } }
}

@Suite struct ReplayWriterTests {
    private func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 3 s at 30 fps with a keyframe every second, kept as a 2-second clip.
    private func twoSecondBuffer(codec: CMVideoCodecType = kCMVideoCodecType_H264) throws -> ReplayBuffer {
        let buffer = ReplayBuffer(clipUs: 2_000_000)
        buffer.feed(try TestVideo.encode(frameCount: 90, fps: 30, keyframeEvery: 30, codec: codec))
        return buffer
    }

    private func checkMovie(_ url: URL, seconds: Double) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - seconds) < 0.1, "duration \(duration)")
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        // The first shown frame decodes, though the movie starts a second after the keyframe it needs.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        let image = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600)).image
        #expect(image.width == 128)
    }

    @Test func writesAnH264MovieWithoutReencoding() async throws {
        let clip = try #require(try twoSecondBuffer().clip())
        #expect(clip.frames.first?.isKeyframe == true)
        #expect(clip.seconds == 2)
        let url = try freshDirectory().appendingPathComponent("clip.mov")
        try await ReplayWriter.write(clip, to: url)
        try await checkMovie(url, seconds: 2)
    }

    @Test func writesAnHEVCMovieWithoutReencoding() async throws {
        let clip = try #require(try twoSecondBuffer(codec: kCMVideoCodecType_HEVC).clip())
        let url = try freshDirectory().appendingPathComponent("clip.mov")
        try await ReplayWriter.write(clip, to: url)
        try await checkMovie(url, seconds: 2)
    }

    @Test func savingHandsPhotosAPlayableMovieThenCleansUp() async throws {
        let saver = FakeVideoSaver(allowed: true)
        let directory = try freshDirectory()
        let result = await ReplaySaver.save(try twoSecondBuffer(), saver: saver, directory: directory)
        #expect(result == .saved(seconds: 2))
        #expect(saver.durations.count == 1)
        #expect(abs((saver.durations.first ?? 0) - 2) < 0.1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func noPhotosPermissionWritesNothing() async throws {
        let saver = FakeVideoSaver(allowed: false)
        let directory = try freshDirectory()
        #expect(await ReplaySaver.save(try twoSecondBuffer(), saver: saver, directory: directory) == .noPermission)
        #expect(saver.urls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func lessThanASecondIsNothingToSave() async throws {
        let short = ReplayBuffer()
        short.feed(try TestVideo.encode(frameCount: 10, fps: 30, keyframeEvery: 30))
        let saver = FakeVideoSaver(allowed: true)
        #expect(await ReplaySaver.save(short, saver: saver, directory: try freshDirectory()) == .nothingToSave)
        #expect(await ReplaySaver.save(ReplayBuffer(), saver: saver, directory: try freshDirectory()) == .nothingToSave)
        #expect(saver.urls.isEmpty)
    }

    @Test func aStillPictureGapKeepsTheMovieLengthAndPlays() async throws {
        // 1 s of video, then nothing for 8 s (a still screen), then 1 s more.
        let encoded = try TestVideo.encode(frameCount: 30, fps: 30, keyframeEvery: 30)
        let buffer = ReplayBuffer()
        buffer.feed(encoded)
        for frame in encoded.frames {
            buffer.append(frame.data, isKeyframe: frame.isKeyframe, ptsUs: frame.ptsUs + 9_000_000, format: encoded.format)
        }
        let clip = try #require(buffer.clip())
        #expect(clip.durationUs > 9_000_000)
        let url = try freshDirectory().appendingPathComponent("gap.mov")
        try await ReplayWriter.write(clip, to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - Double(clip.durationUs) / 1_000_000) < 0.1, "duration \(duration)")
        let generator = AVAssetImageGenerator(asset: asset)
        for second in [0.5, 5.0, 9.5] {
            let image = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
            #expect(image.width == 128)
        }
    }

    @Test func aSaverThatFailsGivesTheFailureResultAndCleansUp() async throws {
        let saver = FakeVideoSaver(allowed: true)
        saver.failure = ReplayWriterError.photosRejectedFile
        let directory = try freshDirectory()
        #expect(await ReplaySaver.save(try twoSecondBuffer(), saver: saver, directory: directory) == .failed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func anUnwritableLocationFailsWithoutALeftoverFile() async throws {
        let clip = try #require(try twoSecondBuffer().clip())
        let missing = try freshDirectory().appendingPathComponent("no-such-folder/clip.mov")
        await #expect(throws: (any Error).self) { try await ReplayWriter.write(clip, to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func anEmptyFrameFailsAndRemovesThePartialFile() async throws {
        let clip = try #require(try twoSecondBuffer().clip())
        var frames = clip.frames
        let last = frames.removeLast()
        frames.append(ReplayFrame(data: Data(), isKeyframe: false, ptsUs: last.ptsUs))
        let broken = ReplayClip(format: clip.format, frames: frames, startUs: clip.startUs, endUs: clip.endUs)
        let url = try freshDirectory().appendingPathComponent("broken.mov")
        await #expect(throws: ReplayWriterError.self) { try await ReplayWriter.write(broken, to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellingAWriteStopsItAndRemovesTheFile() async throws {
        let buffer = ReplayBuffer(clipUs: 20_000_000)
        buffer.feed(try TestVideo.encode(frameCount: 900, fps: 30, keyframeEvery: 30))
        let clip = try #require(buffer.clip())
        let url = try freshDirectory().appendingPathComponent("cancelled.mov")
        let task = Task { try await ReplayWriter.write(clip, to: url) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellingASaveSavesNothingAndCleansUp() async throws {
        let buffer = ReplayBuffer(clipUs: 20_000_000)
        buffer.feed(try TestVideo.encode(frameCount: 900, fps: 30, keyframeEvery: 30))
        let saver = FakeVideoSaver(allowed: true)
        let directory = try freshDirectory()
        let task = Task { await ReplaySaver.save(buffer, saver: saver, directory: directory) }
        task.cancel()
        #expect(await task.value == .failed)
        #expect(saver.urls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func messagesArePlain() {
        #expect(ReplayResult.saved(seconds: 30).message == "Saved the last 30 seconds to Photos")
        #expect(ReplayResult.saved(seconds: 1).message == "Saved the last second to Photos")
        #expect(ReplayResult.noPermission.message.contains("Settings"))
        #expect(ReplayResult.nothingToSave.message == "Nothing to save yet. Play for a few seconds, then try again.")
        #expect(ReplayResult.failed.message == "Couldn't save the clip. Try again.")
        #expect(ReplayResult.saved(seconds: 5).succeeded)
        #expect(!ReplayResult.failed.succeeded)
    }
}
