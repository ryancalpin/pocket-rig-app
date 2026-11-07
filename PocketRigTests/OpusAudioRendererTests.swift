import Testing
import AVFoundation
@testable import PocketRig

@Suite struct OpusAudioRendererTests {
    /// Encodes one Opus packet of `frames` samples with Apple's encoder.
    static func encodePacket(frames: Int) throws -> Data {
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var opusDesc = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                   mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let opusFormat = AVAudioFormat(streamDescription: &opusDesc)!
        let encoder = try #require(AVAudioConverter(from: pcmFormat, to: opusFormat))
        let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { input.floatChannelData![0][i] = sin(Float(i) * 0.1); input.floatChannelData![1][i] = 0 }
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: 1500)
        var fed = false
        var error: NSError?
        encoder.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        #expect(error == nil)
        let size = Int(output.packetDescriptions![0].mDataByteSize)
        return Data(bytes: output.data, count: size)
    }

    @Test func decodesTenMillisecondOpusPacket() throws {
        let packet = try Self.encodePacket(frames: 480)
        let renderer = OpusAudioRenderer(samplesPerFrame: 480)
        // The first decode trims the codec's priming samples, so check steady state.
        let first = try renderer.decode(packet)
        let pcm = try renderer.decode(packet)
        _ = first
        #expect(pcm.frameLength == 480)
    }

    @Test func probeFiveMillisecondEncode() throws {
        // Records what Apple's encoder does with 240-frame packets.
        let packet = try Self.encodePacket(frames: 240)
        let renderer = OpusAudioRenderer(samplesPerFrame: 240)
        let first = try renderer.decode(packet)
        let pcm = try renderer.decode(packet)
        _ = first
        #expect(pcm.frameLength == 240)
        var peak: Float = 0
        for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(pcm.floatChannelData![0][i])) }
        #expect(peak > 0.01)
    }

    @Test func tenMsPacketDecodedWithFiveMsConfig() throws {
        // Observed: a config that does not match the stream yields no frames.
        let packet = try Self.encodePacket(frames: 480)
        let renderer = OpusAudioRenderer(samplesPerFrame: 240)
        let pcm = try renderer.decode(packet)
        #expect(pcm.frameLength == 0)
    }

    @Test func queueAccountingIgnoresStaleCompletions() {
        var q = QueueAccounting()
        let g1 = q.schedule(frames: 240)
        #expect(q.queuedFrames == 240)
        q.reset()
        #expect(q.queuedFrames == 0)
        q.complete(frames: 240, generation: g1)  // stale: must not go negative
        #expect(q.queuedFrames == 0)
        let g2 = q.schedule(frames: 240)
        q.complete(frames: 240, generation: g2)
        #expect(q.queuedFrames == 0)
        q.complete(frames: 240, generation: g2)  // over-complete clamps
        #expect(q.queuedFrames == 0)
    }

    @Test func dropsWhenMoreThanSixtyMillisecondsQueued() {
        #expect(OpusAudioRenderer.shouldDrop(queuedFrames: 0, sampleRate: 48_000) == false)
        #expect(OpusAudioRenderer.shouldDrop(queuedFrames: 2_880, sampleRate: 48_000) == false)
        #expect(OpusAudioRenderer.shouldDrop(queuedFrames: 2_881, sampleRate: 48_000) == true)
    }
}
