import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import PocketRig

/// Real compressed frames for replay tests, made by the phone's own video encoder (it works in the
/// simulator). Same shape as the stream's frames: length-prefixed NAL units plus a format description.
enum TestVideo {
    struct Encoded: @unchecked Sendable {
        let format: CMVideoFormatDescription
        let frames: [ReplayFrame]
    }

    enum Failure: Error { case session(OSStatus), noOutput }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [ReplayFrame] = []
        private var format: CMVideoFormatDescription?

        func add(_ sample: CMSampleBuffer) {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == noErr else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            let ptsUs = UInt64((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1_000_000).rounded())
            let sampleFormat = CMSampleBufferGetFormatDescription(sample)
            lock.withLock {
                if format == nil, isKeyframe { format = sampleFormat }
                frames.append(ReplayFrame(data: data, isKeyframe: isKeyframe, ptsUs: ptsUs))
            }
        }

        var result: (CMVideoFormatDescription?, [ReplayFrame]) { lock.withLock { (format, frames) } }
    }

    /// `frameCount` frames at `fps`, a keyframe every `keyframeEvery`, 128 × 96 pixels.
    static func encode(frameCount: Int, fps: Int, keyframeEvery: Int,
                       codec: CMVideoCodecType = kCMVideoCodecType_H264) throws -> Encoded {
        let width: Int32 = 128, height: Int32 = 96
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &made)
        guard status == noErr, let session = made else { throw Failure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let collector = Collector()
        for index in 0..<frameCount {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, nil, &made)
            guard let pixels = made else { throw Failure.noOutput }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(index * 4 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            let options: CFDictionary? = index % keyframeEvery == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                            frameProperties: options, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample else { return }
                collector.add(sample)
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let (format, frames) = collector.result
        guard let format, !frames.isEmpty else { throw Failure.noOutput }
        return Encoded(format: format, frames: frames)
    }
}

extension ReplayBuffer {
    /// Test helper: every frame of `encoded`, in order.
    func feed(_ encoded: TestVideo.Encoded) {
        for frame in encoded.frames {
            append(frame.data, isKeyframe: frame.isKeyframe, ptsUs: frame.ptsUs, format: encoded.format)
        }
    }
}
