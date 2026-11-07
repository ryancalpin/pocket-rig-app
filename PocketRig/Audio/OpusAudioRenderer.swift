import AVFoundation
import os

/// Tracks queued frames. A generation token keeps completions from before a `reset()` from
/// corrupting the count afterwards.
struct QueueAccounting {
    private(set) var queuedFrames = 0
    private(set) var generation = 0

    mutating func schedule(frames: Int) -> Int {
        queuedFrames += frames
        return generation
    }

    mutating func complete(frames: Int, generation: Int) {
        guard generation == self.generation else { return }
        queuedFrames = max(0, queuedFrames - frames)
    }

    mutating func reset() {
        generation += 1
        queuedFrames = 0
    }
}

/// Decodes Opus packets (stereo) with Apple's decoder and plays them with a small queue.
final class OpusAudioRenderer: @unchecked Sendable {
    enum AudioError: Error { case formatUnavailable, converterUnavailable, decodeFailed(String) }

    static let maxQueuedSeconds = 0.060

    private let sampleRate: Double
    private let samplesPerFrame: UInt32
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let decodeLock = OSAllocatedUnfairLock()
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let log = Logger(subsystem: "com.ryancalpin.pocketrig", category: "audio")

    /// Everything the audio thread and the control thread share, guarded by `state`.
    private struct State {
        var engine: AVAudioEngine?
        var player: AVAudioPlayerNode?
        var accounting = QueueAccounting()
        var observers: [NSObjectProtocol] = []
        var droppedPackets = 0
        var decodeFailures = 0
    }

    /// Packets skipped because the queue was over budget.
    var droppedPackets: Int { state.withLockUnchecked { $0.droppedPackets } }
    /// Packets the decoder rejected or returned empty.
    var decodeFailures: Int { state.withLockUnchecked { $0.decodeFailures } }
    /// Frames currently scheduled but not yet played.
    var queuedFrames: Int { state.withLockUnchecked { $0.accounting.queuedFrames } }

    init(sampleRate: Double = 48_000, channels: UInt32 = 2, samplesPerFrame: UInt32 = 240) {
        self.sampleRate = sampleRate
        self.samplesPerFrame = samplesPerFrame
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  channels: channels, interleaved: false)!
        var desc = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: samplesPerFrame, mBytesPerFrame: 0,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        opusFormat = AVAudioFormat(streamDescription: &desc)!
        converter = AVAudioConverter(from: opusFormat, to: pcmFormat)
    }

    /// True when the already-queued audio is longer than the 60 ms budget.
    static func shouldDrop(queuedFrames: Int, sampleRate: Double) -> Bool {
        Double(queuedFrames) / sampleRate > maxQueuedSeconds
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard let converter else { throw AudioError.converterUnavailable }
        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1,
                                                 maximumPacketSize: max(packet.count, 1))
        packet.withUnsafeBytes { raw in
            if let base = raw.baseAddress, packet.count > 0 {
                memcpy(compressed.data, base, packet.count)
            }
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions![0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: samplesPerFrame) else {
            throw AudioError.formatUnavailable
        }
        var fed = false
        var error: NSError?
        let status = decodeLock.withLockUnchecked {
            converter.convert(to: out, error: &error) { _, inStatus in
                if fed { inStatus.pointee = .noDataNow; return nil }
                fed = true; inStatus.pointee = .haveData; return compressed
            }
        }
        if let error { throw AudioError.decodeFailed(error.localizedDescription) }
        if status == .error { throw AudioError.decodeFailed("converter status error") }
        return out
    }

    func start() throws {
        if state.withLockUnchecked({ $0.engine != nil }) { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        do {
            try engine.start()
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        player.play()

        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) else { return }
            self?.restart()
        }
        let config = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: nil) { [weak self] _ in
            self?.restart()
        }
        let installed = state.withLockUnchecked { s -> Bool in
            guard s.engine == nil else { return false }
            s.engine = engine
            s.player = player
            s.accounting.reset()
            s.observers = [interruption, config]
            return true
        }
        if !installed {
            // Lost a start/start race: tear down our duplicate.
            center.removeObserver(interruption)
            center.removeObserver(config)
            player.stop()
            engine.stop()
        }
    }

    /// Restarts the engine and player after an interruption or route/config change.
    private func restart() {
        let (engine, player) = state.withLockUnchecked { s -> (AVAudioEngine?, AVAudioPlayerNode?) in
            s.accounting.reset()  // buffers queued before the stop never complete normally
            return (s.engine, s.player)
        }
        guard let engine, let player else { return }
        // stop() can run while we restart; only act while this engine is still the current one.
        func isCurrent() -> Bool { state.withLockUnchecked { $0.engine === engine } }
        guard isCurrent() else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            log.error("Audio restart failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // stop() ran in the meantime: it already tore the engine down before we restarted it, so undo that.
        if !isCurrent() {
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Called from the streaming audio thread. Returns what was decoded (played or dropped), for
    /// "feel the sound"; nil when the packet couldn't be decoded.
    @discardableResult
    func play(_ packet: Data) -> AVAudioPCMBuffer? {
        // Decode first so the Opus decoder state stays continuous even when we drop.
        let buffer: AVAudioPCMBuffer
        do {
            buffer = try decode(packet)
            if buffer.frameLength == 0 { throw AudioError.decodeFailed("empty output") }
        } catch {
            let count = state.withLockUnchecked { s -> Int in s.decodeFailures += 1; return s.decodeFailures }
            if count == 1 || count % 100 == 0 {
                log.error("Opus decode failed (\(count) total): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        let frames = Int(buffer.frameLength)
        let scheduled: (AVAudioPlayerNode, Int)? = state.withLockUnchecked { s in
            guard let player = s.player else { return nil }
            if Self.shouldDrop(queuedFrames: s.accounting.queuedFrames, sampleRate: sampleRate) {
                s.droppedPackets += 1
                return nil
            }
            return (player, s.accounting.schedule(frames: frames))
        }
        guard let (player, generation) = scheduled else { return buffer }
        player.scheduleBuffer(buffer) { [state] in
            state.withLockUnchecked { $0.accounting.complete(frames: frames, generation: generation) }
        }
        return buffer
    }

    func stop() {
        let (engine, player, observers) = state.withLockUnchecked { s in
            let taken = (s.engine, s.player, s.observers)
            s.engine = nil
            s.player = nil
            s.observers = []
            s.accounting.reset()
            return taken
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        player?.stop()
        engine?.stop()
        if engine != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
