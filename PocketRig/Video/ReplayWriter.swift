import AVFoundation
import CoreMedia
import Foundation
import Photos
import os

private let replayLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "replay")

/// How "Save last 30 seconds" went, in plain words for the Quick menu.
enum ReplayResult: Equatable, Sendable {
    case saved(seconds: Int), noPermission, nothingToSave, failed

    var message: String {
        switch self {
        case .saved(let seconds):
            seconds == 1 ? "Saved the last second to Photos" : "Saved the last \(seconds) seconds to Photos"
        case .noPermission: "Pocket Rig can't save to Photos. Allow it in Settings › Pocket Rig › Photos."
        case .nothingToSave: "Nothing to save yet. Play for a few seconds, then try again."
        case .failed: "Couldn't save the clip. Try again."
        }
    }

    var succeeded: Bool {
        if case .saved = self { return true }
        return false
    }
}

enum ReplayWriterError: Error { case cannotStart, emptyFrame, appendFailed, finishFailed, photosRejectedFile }

/// Writes a clip to a QuickTime movie without re-encoding: the PC's frames go into the file as they are.
/// No sound: game audio arrives as Opus packets whose timing doesn't line up with the video.
enum ReplayWriter {
    static func write(_ clip: ReplayClip, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        do {
            try await append(clip, with: writer)
        } catch {
            // Stops the writer and removes the half-written file.
            writer.cancelWriting()
            throw error
        }
    }

    private static func append(_ clip: ReplayClip, with writer: AVAssetWriter) async throws {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: clip.format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ReplayWriterError.cannotStart }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ReplayWriterError.cannotStart }
        // Frames before startUs only lead up to the first shown frame; the movie begins at startUs.
        writer.startSession(atSourceTime: time(clip.startUs))
        for (index, frame) in clip.frames.enumerated() {
            try Task.checkCancellation()
            let nextUs = index + 1 < clip.frames.count ? clip.frames[index + 1].ptsUs : clip.endUs
            let sample = try sampleBuffer(frame, durationUs: max(1, nextUs - frame.ptsUs), format: clip.format)
            while !input.isReadyForMoreMediaData {
                // The writer can fail or be stopped while we wait; it would never become ready again.
                guard writer.status == .writing else { throw writer.error ?? ReplayWriterError.appendFailed }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.append(sample) else { throw writer.error ?? ReplayWriterError.appendFailed }
        }
        try Task.checkCancellation()
        input.markAsFinished()
        writer.endSession(atSourceTime: time(clip.endUs))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ReplayWriterError.finishFailed }
    }

    private static func time(_ us: UInt64) -> CMTime { CMTime(value: CMTimeValue(us), timescale: 1_000_000) }

    private static func sampleBuffer(_ frame: ReplayFrame, durationUs: UInt64,
                                     format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        guard !frame.data.isEmpty else { throw ReplayWriterError.emptyFrame }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: frame.data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frame.data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw VideoFormatBuilder.BuildError.status(status) }
        status = frame.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: frame.data.count)
        }
        guard status == noErr else { throw VideoFormatBuilder.BuildError.status(status) }
        var timing = CMSampleTimingInfo(duration: time(durationUs), presentationTimeStamp: time(frame.ptsUs),
                                        decodeTimeStamp: .invalid) // No B-frames in this stream (ReplayBuffer enforces increasing pts), so decode order = show order.
        var size = frame.data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoFormatBuilder.BuildError.status(status) }
        if !frame.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Where a finished clip goes. Photos in the app; a fake in tests.
protocol VideoSaving: Sendable {
    func requestAccess() async -> Bool
    func saveVideo(at url: URL) async throws
}

/// Saves into the photo library with add-only access (Pocket Rig never reads anyone's photos).
struct PhotoLibraryVideoSaver: VideoSaving {
    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    func saveVideo(at url: URL) async throws {
        let accepted = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            let isAccepted = request != nil
            accepted.withLock { $0 = isAccepted }
        }
        guard accepted.withLock({ $0 }) else { throw ReplayWriterError.photosRejectedFile }
    }
}

/// "Save last 30 seconds": asks for Photos access first, writes the movie off the main thread, hands it to
/// Photos, and always deletes the temporary file.
enum ReplaySaver {
    /// Less than a second isn't worth a clip.
    static let minimumUs: UInt64 = 1_000_000

    static func save(_ buffer: ReplayBuffer, saver: any VideoSaving = PhotoLibraryVideoSaver(),
                     directory: URL = FileManager.default.temporaryDirectory) async -> ReplayResult {
        guard let clip = buffer.clip(), clip.durationUs >= minimumUs else { return .nothingToSave }
        guard await saver.requestAccess() else { return .noPermission }
        let url = directory.appendingPathComponent("PocketRig-replay-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // Writing runs off the main thread; a detached task doesn't inherit cancellation, so pass it on.
            let writing = Task.detached(priority: .userInitiated) { try await ReplayWriter.write(clip, to: url) }
            try await withTaskCancellationHandler { try await writing.value } onCancel: { writing.cancel() }
            try Task.checkCancellation()
            try await saver.saveVideo(at: url)
            return .saved(seconds: clip.seconds)
        } catch {
            replayLog.error("Saving replay failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }
}
