import CMoonlight
import Foundation
import Observation
import os

/// Why a stream failed, in terms the UI can explain. Raw stage names and codes go to the log instead.
enum StreamFailure: Equatable, Sendable {
    /// The PC didn't answer the launch request.
    case unreachable
    /// The PC answered but refused or couldn't start the app.
    case launchRejected
    /// The video connection couldn't be set up.
    case startFailed
    /// The connection dropped mid-stream.
    case disconnected
}

enum StreamState: Equatable, Sendable {
    case idle, launching, connecting(stage: String), streaming, failed(StreamFailure), ended
}

enum StreamEvent: Sendable {
    case stageStarting(String)
    case stageFailed(String, Int32)
    case started
    case terminated(Int32)
    case connectionStatus(Int32)
    case feedback(HostFeedback)
}

private let moonlightLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "moonlight")
private let sessionLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "stream")

/// The renderers moonlight-common-c's C callbacks reach. Its callbacks carry no user pointer and only one
/// stream runs at a time, so they find the bridge through this global. It is set on `streamQueue` before
/// `LiStartConnection` and cleared there only after `LiStopConnection` returns, so every moonlight thread
/// that reads it runs strictly between those two writes.
nonisolated(unsafe) private var activeBridge: StreamBridge?

/// `LiStartConnection`/`LiStopConnection` aren't thread-safe; this serial queue keeps them from overlapping
/// across every session in the process.
private let streamQueue = DispatchQueue(label: "com.ryancalpin.pocketrig.stream", qos: .userInitiated)

/// Owns everything the C callbacks touch. Not an actor: video and audio callbacks run on moonlight's
/// receive threads and must not hop anywhere (lowest latency).
final class StreamBridge: @unchecked Sendable {
    let video: VideoRenderer
    let onEvent: @Sendable (StreamEvent) -> Void
    let audioEnabled: Bool

    private struct State {
        var audio: OpusAudioRenderer?
        var soundTap = false
        var bass: BassEnvelope?
        /// A level waiting for the ~60 per second send limit, and when one was last sent.
        var pendingLevel: Float?
        var lastLevelSent: UInt64 = 0
        var framesSubmitted = 0
        var idrFramesSubmitted = 0
        var framesRejected = 0
        var cStrings: [UnsafeMutablePointer<CChar>] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(video: VideoRenderer, audioEnabled: Bool = true, onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.video = video
        self.audioEnabled = audioEnabled
        self.onEvent = onEvent
    }

    /// Frames the renderer accepted (DR_OK).
    var framesSubmitted: Int { state.withLockUnchecked { $0.framesSubmitted } }
    /// IDR frames the renderer accepted (DR_OK).
    var idrFramesSubmitted: Int { state.withLockUnchecked { $0.idrFramesSubmitted } }
    /// Frames the renderer rejected (DR_NEED_IDR), each of which asks the host for a new IDR.
    var framesRejected: Int { state.withLockUnchecked { $0.framesRejected } }

    /// strdup's a C string that stays alive until `freeCStrings()`.
    func keepCString(_ string: String?) -> UnsafePointer<CChar>? {
        guard let string, let copy = strdup(string) else { return nil }
        state.withLockUnchecked { $0.cStrings.append(copy) }
        return UnsafePointer(copy)
    }

    func freeCStrings() {
        let strings = state.withLockUnchecked { s in
            let taken = s.cStrings
            s.cStrings = []
            return taken
        }
        strings.forEach { free($0) }
    }

    // MARK: Video (moonlight receive thread)

    fileprivate func setupVideo(format: Int32) -> Int32 {
        video.setup(codec: format & Int32(VIDEO_FORMAT_MASK_H265) != 0 ? .hevc : .h264)
        return 0
    }

    fileprivate func submit(_ du: PDECODE_UNIT) -> Int32 {
        var units: [(type: Int32, data: Data)] = []
        var entry = du.pointee.bufferList
        while let current = entry {
            if let data = current.pointee.data, current.pointee.length > 0 {
                units.append((current.pointee.bufferType, Data(bytes: data, count: Int(current.pointee.length))))
            }
            entry = current.pointee.next
        }
        let isIDR = du.pointee.frameType == FRAME_TYPE_IDR
        let timing = FrameTiming(receiveUs: du.pointee.receiveTimeUs,
                                 hostLatencyTenthsMs: du.pointee.frameHostProcessingLatency)
        let result = video.submit(units: units, isIDR: isIDR, timing: timing, ptsUs: du.pointee.presentationTimeUs)
        // Instant replay: Sunshine sends a keyframe only when asked, so ask now and then, so the last
        // 30 seconds always start at one. Safe here: this callback only runs while connected.
        if result == DR_OK, video.replay.shouldRequestKeyframe() { LiRequestIdrFrame() }
        state.withLockUnchecked { s in
            if result == DR_OK {
                s.framesSubmitted += 1
                if isIDR { s.idrFramesSubmitted += 1 }
            } else {
                s.framesRejected += 1
            }
        }
        return result
    }

    // MARK: Audio (moonlight audio thread)

    fileprivate func initAudio(_ opus: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 {
        // Audio switched off (DEBUG `-pr.noAudio`): no renderer, so incoming packets are dropped in `play`.
        guard audioEnabled else { return 0 }
        let renderer = OpusAudioRenderer(sampleRate: Double(opus.sampleRate), channels: UInt32(opus.channelCount),
                                         samplesPerFrame: UInt32(opus.samplesPerFrame))
        do {
            try renderer.start()
        } catch {
            // Keep streaming video without sound rather than failing the whole connection.
            sessionLog.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        state.withLockUnchecked { $0.audio = renderer }
        return 0
    }

    fileprivate func play(_ sample: UnsafeMutablePointer<CChar>, length: Int32) {
        guard length > 0, let audio = state.withLockUnchecked({ $0.audio }) else { return }
        guard let pcm = audio.play(Data(bytes: sample, count: Int(length))) else { return }
        // "Feel the sound": measure the bass here, outside the lock. Only this thread touches `bass`.
        guard state.withLockUnchecked({ $0.soundTap }) else { return }
        var bass = state.withLockUnchecked { $0.bass } ?? BassEnvelope(sampleRate: pcm.format.sampleRate)
        let report = bass.process(pcm)
        let now = DispatchTime.now().uptimeNanoseconds
        // At most ~60 levels a second reach the main thread; the newest waits for the next slot. A 0 (the bass
        // faded out) always goes at once, so the motor can't keep buzzing if audio packets stop arriving.
        let toSend: Float? = state.withLockUnchecked { s in
            guard s.soundTap else { return nil }
            s.bass = bass
            if let report { s.pendingLevel = report }
            guard let level = s.pendingLevel,
                  level == 0 || now &- s.lastLevelSent >= 16_000_000 else { return nil }
            s.pendingLevel = nil
            s.lastLevelSent = now
            return level
        }
        if let toSend { onEvent(.feedback(.soundLevel(toSend))) }
    }

    /// Turns "feel the sound" listening on or off; off forgets the measured level.
    func setSoundTap(_ on: Bool) {
        state.withLockUnchecked { s in
            s.soundTap = on
            if !on {
                s.bass = nil
                s.pendingLevel = nil
            }
        }
    }

    func stopAudio() {
        let audio = state.withLockUnchecked { s in
            let taken = s.audio
            s.audio = nil
            return taken
        }
        audio?.stop()
    }
}

// MARK: C callbacks (capture nothing; reach state through `activeBridge`)

private func stageName(_ stage: Int32) -> String {
    String(cString: LiGetStageName(stage))
}

private func makeVideoCallbacks() -> DECODER_RENDERER_CALLBACKS {
    var dr = DECODER_RENDERER_CALLBACKS()
    LiInitializeVideoCallbacks(&dr)
    dr.setup = { format, _, _, _, _, _ in activeBridge?.setupVideo(format: format) ?? -1 }
    dr.submitDecodeUnit = { du in
        guard let du, let bridge = activeBridge else { return DR_OK }
        return bridge.submit(du)
    }
    dr.capabilities = CAPABILITY_DIRECT_SUBMIT
    return dr
}

private func makeAudioCallbacks() -> AUDIO_RENDERER_CALLBACKS {
    var ar = AUDIO_RENDERER_CALLBACKS()
    LiInitializeAudioCallbacks(&ar)
    ar.`init` = { _, opus, _, _ in
        guard let opus, let bridge = activeBridge else { return -1 }
        return bridge.initAudio(opus.pointee)
    }
    ar.cleanup = { activeBridge?.stopAudio() }
    ar.decodeAndPlaySample = { sample, length in
        guard let sample else { return }
        activeBridge?.play(sample, length: length)
    }
    ar.capabilities = CAPABILITY_DIRECT_SUBMIT | CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION
    return ar
}

private func makeConnectionCallbacks() -> CONNECTION_LISTENER_CALLBACKS {
    var cl = CONNECTION_LISTENER_CALLBACKS()
    LiInitializeConnectionCallbacks(&cl)
    cl.stageStarting = { stage in activeBridge?.onEvent(.stageStarting(stageName(stage))) }
    cl.stageFailed = { stage, code in activeBridge?.onEvent(.stageFailed(stageName(stage), code)) }
    cl.connectionStarted = { activeBridge?.onEvent(.started) }
    cl.connectionTerminated = { code in activeBridge?.onEvent(.terminated(code)) }
    cl.connectionStatusUpdate = { status in activeBridge?.onEvent(.connectionStatus(status)) }
    cl.rumble = { controller, low, high in
        activeBridge?.onEvent(.feedback(.rumble(controller: controller, low: low, high: high)))
    }
    cl.rumbleTriggers = { controller, left, right in
        activeBridge?.onEvent(.feedback(.triggerRumble(controller: controller, left: left, right: right)))
    }
    cl.setMotionEventState = { controller, type, rate in
        activeBridge?.onEvent(.feedback(.motionRequest(controller: controller, type: type, rateHz: rate)))
    }
    PRSetLogSink { message in
        guard let message else { return }
        let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { moonlightLog.info("\(text, privacy: .public)") }
    }
    PRInstallLogCallback(&cl)
    return cl
}

// MARK: Session

/// Launches (or resumes) an app on the host, then runs the moonlight-common-c stream into `video` and audio.
@MainActor @Observable final class StreamSession {
    let video: VideoRenderer
    private(set) var state: StreamState = .idle
    private(set) var connectionQuality: ConnectionQuality = .unknown

    private let api: HostAPI
    private let serverInfo: ServerInfo
    private let address: String
    private let appID: Int
    private(set) var settings: StreamSettings
    @ObservationIgnored private var bridge: StreamBridge?
    /// True from dispatching `LiStartConnection` until `LiStopConnection` has run for it.
    @ObservationIgnored private var connectionActive = false
    /// Identifies the current bridge so late events from an earlier stream are ignored.
    @ObservationIgnored private(set) var bridgeToken = UUID()
    /// Delivers one stream's events to the main actor in the order moonlight sent them (a rumble "stop"
    /// must never overtake the rumble it ends). Finished when the stream stops or is replaced.
    @ObservationIgnored private var eventSink: AsyncStream<StreamEvent>.Continuation?
    /// Bumped by every start() and stop(); a start() whose generation is stale has been superseded.
    @ObservationIgnored private var generation = 0
    /// The app running on the host as far as we know; starts from serverinfo and tracks our own launches,
    /// so starting again after a stop resumes instead of relaunching.
    @ObservationIgnored private var hostGameID: Int
    /// Rumble, trigger rumble, motion requests and sound level, delivered only while connecting or streaming.
    @ObservationIgnored var onHostFeedback: @MainActor (HostFeedback) -> Void = { _ in }
    /// Whether game audio is measured for "feel the sound". Survives reconnects.
    @ObservationIgnored private var soundTap = false

    func setSoundTap(_ on: Bool) {
        soundTap = on
        bridge?.setSoundTap(on)
    }

    init(api: HostAPI, serverInfo: ServerInfo, address: String, appID: Int, settings: StreamSettings) {
        self.api = api
        self.serverInfo = serverInfo
        self.address = address
        self.appID = appID
        self.settings = settings
        self.hostGameID = serverInfo.currentGameID
        self.video = VideoRenderer()
    }

    /// Video frames the renderer accepted in the current or last stream.
    var framesSubmitted: Int { bridge?.framesSubmitted ?? 0 }
    /// IDR frames the renderer accepted in the current or last stream.
    var idrFramesSubmitted: Int { bridge?.idrFramesSubmitted ?? 0 }
    /// Video frames the renderer rejected in the current or last stream.
    var framesRejected: Int { bridge?.framesRejected ?? 0 }

    /// Numbers for the Stats tab. The round trip is only known while streaming.
    func statsSnapshot() -> StatsSnapshot {
        var rtt: UInt32 = 0, variance: UInt32 = 0
        var hasRTT = false
        if state == .streaming, connectionActive { hasRTT = LiGetEstimatedRttInfo(&rtt, &variance) }
        return StatsSnapshot(rttMs: hasRTT ? Double(rtt) : nil, rttVarianceMs: hasRTT ? Double(variance) : nil,
                             frames: video.stats.current(nowUs: LiGetMicroseconds()), quality: connectionQuality)
    }

    func start() async {
        switch state {
        case .idle, .ended, .failed: break
        default: return
        }
        state = .launching
        connectionQuality = .unknown
        video.stats.reset()
        generation += 1
        let myGeneration = generation
        let riKey = StreamConfigurationBuilder.makeRemoteInputKey()
        let extraQuery = String(cString: LiGetLaunchUrlQueryParameters())
        let launch: LaunchResult
        do {
            if hostGameID == appID {
                launch = try await api.resume(riKey: riKey.key, riKeyID: riKey.keyID,
                                              surroundAudioInfo: StreamConfigurationBuilder.surroundAudioInfo,
                                              extraQuery: extraQuery,
                                              mode: StreamConfigurationBuilder.modeString(settings))
            } else {
                if hostGameID != 0 {
                    try await api.cancel()
                    hostGameID = 0
                }
                launch = try await api.launch(appID: appID, mode: StreamConfigurationBuilder.modeString(settings),
                                              riKey: riKey.key, riKeyID: riKey.keyID,
                                              surroundAudioInfo: StreamConfigurationBuilder.surroundAudioInfo,
                                              extraQuery: extraQuery)
                hostGameID = appID
            }
        } catch {
            sessionLog.error("Launch failed: \(String(describing: error), privacy: .public)")
            if generation == myGeneration {
                state = .failed(error as? HostError == .unreachable ? .unreachable : .launchRejected)
            }
            return
        }
        // stop() during the launch request wins.
        guard generation == myGeneration, state == .launching else { return }
        state = .connecting(stage: "Starting")

        let token = UUID()
        bridgeToken = token
        eventSink?.finish()
        let (events, sink) = AsyncStream<StreamEvent>.makeStream()
        eventSink = sink
        Task { @MainActor [weak self] in
            for await event in events { self?.handle(event, token: token) }
        }
        let bridge = StreamBridge(video: video, audioEnabled: settings.audioEnabled) { event in
            sink.yield(event)
        }
        self.bridge = bridge
        bridge.setSoundTap(soundTap)
        connectionActive = true

        let config = StreamConfigurationBuilder.streamConfiguration(
            settings: settings, address: address, riKey: riKey, serverCodecSupport: serverInfo.codecModeSupport)
        let address = address, appVersion = serverInfo.appVersion, gfeVersion = serverInfo.gfeVersion
        let codecSupport = serverInfo.codecModeSupport, sessionURL = launch.sessionURL
        let rc: Int32 = await withCheckedContinuation { continuation in
            streamQueue.async {
                var server = SERVER_INFORMATION()
                LiInitializeServerInformation(&server)
                server.address = bridge.keepCString(address)
                server.serverInfoAppVersion = bridge.keepCString(appVersion)
                server.serverInfoGfeVersion = bridge.keepCString(gfeVersion)
                server.rtspSessionUrl = bridge.keepCString(sessionURL)
                server.serverCodecModeSupport = codecSupport
                var stream = config
                var cl = makeConnectionCallbacks()
                var dr = makeVideoCallbacks()
                var ar = makeAudioCallbacks()
                activeBridge = bridge
                let rc = LiStartConnection(&server, &stream, &cl, &dr, &ar, nil, 0, nil, 0)
                if rc != 0 {
                    // LiStartConnection already undid its own work; nothing reads the bridge now.
                    activeBridge = nil
                    bridge.stopAudio()
                    bridge.freeCStrings()
                }
                continuation.resume(returning: rc)
            }
        }
        guard self.bridge === bridge, rc != 0 else { return }
        connectionActive = false
        video.reset()
        // A stageFailed event usually already set a more specific failure; stop() owns the state if it ran.
        sessionLog.error("LiStartConnection returned \(rc)")
        if generation == myGeneration, !isFailed { state = .failed(.startFailed) }
    }

    /// Right away and without waiting: from now on nothing from the current stream reaches the screen. The
    /// resize controller calls this before it silences the motors, so a rumble still queued from the old
    /// stream can't restart them during the reconnect. `reconnect(with:)` swaps the token again later.
    func beginReconnect() {
        switch state {
        case .connecting, .streaming: break
        default: return
        }
        bridgeToken = UUID()
        eventSink?.finish()
        eventSink = nil
    }

    func stop() async {
        generation += 1
        bridgeToken = UUID()  // ignore any events still in flight from this stream
        eventSink?.finish()
        eventSink = nil
        // Abort a start that is still handshaking; LiStopConnection then queues behind it.
        if connectionActive { LiInterruptConnection() }
        await teardown()
        if !isFailed { state = .ended }
    }

    /// Restarts the stream with new settings (the game area changed size). Stock Sunshine can't resize a
    /// running stream, so this is a quick stop and resume; the game keeps running on the PC.
    func reconnect(with newSettings: StreamSettings) async {
        // Only a live session reconnects. Anything else (not started, ended, failed) just remembers the
        // settings, so a late resize can't revive a finished stream.
        switch state {
        case .connecting, .streaming: break
        case .launching, .idle, .ended, .failed:
            // While the launch request is still in flight, a second /launch or /cancel could kill the game
            // it is starting. The RTSP stream setup reads `settings` after the launch returns, so the
            // in-flight start picks up the new size on its own.
            settings = newSettings
            return
        }
        generation += 1
        let myGeneration = generation
        bridgeToken = UUID()  // ignore late events from the old stream
        eventSink?.finish()
        eventSink = nil
        if connectionActive { LiInterruptConnection() }
        await teardown()
        // A stop() or a newer reconnect ran while we tore down: it owns the session now.
        guard generation == myGeneration else { return }
        settings = newSettings
        state = .idle
        await start()
    }

    /// A stopped session (ended, failed, not started) starts next time with these settings. A live or
    /// launching one keeps its own: changing those is `reconnect(with:)`'s job.
    func updateSettings(_ newSettings: StreamSettings) {
        switch state {
        case .idle, .ended, .failed: settings = newSettings
        case .launching, .connecting, .streaming: break
        }
    }

    /// Tests only: puts the session in a state without a real stream.
    func setStateForTesting(_ newState: StreamState) { state = newState }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func handle(_ event: StreamEvent, token: UUID) {
        guard token == bridgeToken else { return }
        switch event {
        case .stageStarting(let name):
            if case .connecting = state { state = .connecting(stage: name) }
        case .stageFailed(let name, let code):
            sessionLog.error("Stage \(name, privacy: .public) failed (\(code))")
            if case .connecting = state { state = .failed(.startFailed) }
        case .started:
            if case .connecting = state { state = .streaming }
        case .terminated(let code):
            guard state == .streaming || isConnecting else { return }
            if code != 0 { sessionLog.error("Connection terminated (\(code))") }
            state = code == 0 ? .ended : .failed(.disconnected)
            Task { await teardown() }
        case .connectionStatus(let status):
            switch state {
            case .ended, .failed: return
            default: break
            }
            connectionQuality = status == CONN_STATUS_POOR ? .poor : .good
        case .feedback(let feedback):
            guard state == .streaming || isConnecting else { return }
            onHostFeedback(feedback)
        }
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    /// Stops the connection (if any) and releases renderers. Never call `/cancel`: the game keeps running
    /// on the PC so Resume works.
    private func teardown() async {
        guard connectionActive, let bridge else {
            video.reset()
            return
        }
        connectionActive = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            streamQueue.async {
                if activeBridge === bridge {
                    LiStopConnection()
                    activeBridge = nil
                }
                bridge.stopAudio()
                bridge.freeCStrings()
                continuation.resume()
            }
        }
        video.reset()
    }
}
