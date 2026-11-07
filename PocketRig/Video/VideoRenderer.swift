import AVFoundation
import CMoonlight
import Foundation

/// Turns moonlight's Annex B decode units into hardware-decoded frames on an
/// `AVSampleBufferDisplayLayer`. Every sample is flagged display-immediately and
/// enqueued the moment it arrives, so nothing is buffered.
final class VideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    /// Rolling frame rate and timing for the Stats tab.
    let stats = FrameStatsRecorder()
    /// The last 30 seconds of compressed frames, for instant replay.
    let replay = ReplayBuffer()

    private let lock = NSLock()
    private var codec: VideoCodec = .h264
    private var vps: [Data] = []
    private var sps: [Data] = []
    private var pps: [Data] = []
    private var format: CMVideoFormatDescription?
    private var formatSource: [Data] = []
    /// The layer's renderer, looked up once here. In the iOS 27 SDK the layer's `sampleBufferRenderer` property
    /// is main-actor only, but decoding happens on moonlight's decoder thread. The renderer object itself is
    /// built to be fed from any thread (enqueue, flush, status), and a layer keeps the same renderer for its
    /// whole life, so holding it in a `let` and using it off the main actor is safe.
    private let renderer: AVSampleBufferVideoRenderer

    /// On the main actor: the layer's display properties may only be set there.
    @MainActor init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
    }

    func setup(codec: VideoCodec) {
        lock.lock()
        self.codec = codec
        clearStateLocked()
        lock.unlock()
        replay.reset()
        renderer.flush()
    }

    /// Called on moonlight's decoder thread. Returns DR_OK or DR_NEED_IDR.
    /// `ptsUs`: the frame's time on the stream clock (`DECODE_UNIT.presentationTimeUs`).
    func submit(units: [(type: Int32, data: Data)], isIDR: Bool, timing: FrameTiming? = nil, ptsUs: UInt64) -> Int32 {
        var pictureFragments: [Data] = []
        var newVPS: [Data] = [], newSPS: [Data] = [], newPPS: [Data] = []
        var sawVPS = false, sawSPS = false, sawPPS = false
        for unit in units {
            switch unit.type {
            case BUFFER_TYPE_VPS: sawVPS = true; newVPS += NALUnitParser.split(annexB: unit.data)
            case BUFFER_TYPE_SPS: sawSPS = true; newSPS += NALUnitParser.split(annexB: unit.data)
            case BUFFER_TYPE_PPS: sawPPS = true; newPPS += NALUnitParser.split(annexB: unit.data)
            default: pictureFragments.append(unit.data)
            }
        }
        // Picture data arrives in packet-sized pieces; join before splitting.
        let picture = NALUnitParser.split(fragments: pictureFragments)

        lock.lock()
        if sawVPS { vps = newVPS }
        if sawSPS { sps = newSPS }
        if sawPPS { pps = newPPS }
        if isIDR {
            let sets = (codec == .hevc ? vps : []) + sps + pps
            if !sets.isEmpty, sets != formatSource || format == nil {
                if let built = try? VideoFormatBuilder.formatDescription(codec: codec, parameterSets: sets) {
                    format = built
                    formatSource = sets
                }
            }
        }
        let currentFormat = format
        lock.unlock()

        guard let currentFormat, !picture.isEmpty else { replay.noteGap(); return DR_NEED_IDR }
        let avcc = NALUnitParser.lengthPrefixed(picture)
        guard let sample = try? VideoFormatBuilder.sampleBuffer(avcc: avcc, format: currentFormat) else {
            replay.noteGap()
            return DR_NEED_IDR
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            replay.noteGap()
            return DR_NEED_IDR
        }
        renderer.enqueue(sample)
        replay.append(avcc, isKeyframe: isIDR, ptsUs: ptsUs, format: currentFormat)
        if let timing { stats.record(timing, nowUs: LiGetMicroseconds()) }
        return DR_OK
    }

    func reset() {
        lock.lock()
        clearStateLocked()
        lock.unlock()
        stats.reset()
        replay.reset()
        renderer.flush()
    }

    private func clearStateLocked() {
        vps = []; sps = []; pps = []
        format = nil
        formatSource = []
    }
}
