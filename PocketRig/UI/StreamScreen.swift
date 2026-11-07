import GameController
import SwiftData
import SwiftUI
import UIKit

/// The stream: game picture and deck arranged for the current pose (`StreamLayoutView`). The stream
/// resolution matches the game area; a lasting size change (fold, rotate) triggers a quick reconnect.
struct StreamScreen: View {
    let host: Host
    let appID: Int
    @Environment(PoseMonitor.self) private var poses

    var body: some View {
        // Build the deck from the current pose, so the first frame already has the right buttons.
        StreamScreenBody(host: host, appID: appID,
                         initialPose: poses.pose.streamingPose(in: poses.windowSize).layoutPose)
    }
}

private struct StreamScreenBody: View {
    let host: Host
    let appID: Int
    @Environment(AppModel.self) private var model
    @Environment(PoseMonitor.self) private var poses
    @Environment(\.modelContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var session: StreamSession?
    @State private var connectError: String?
    @State private var deck: DeckModel
    @State private var monitor = PhysicalControllerMonitor(sender: MoonlightControllerSender())
    /// The game area in points; zero until the first layout pass.
    @State private var gameArea: CGSize = .zero
    @State private var resizer: StreamResizeController?
    @State private var hasStreamed = false
    /// The PC's encoder limit (width × height), when it reports one.
    @State private var maxPixels: Int?
    @State private var editing = false
    /// The phone's motor and what drives it; one of each per stream screen.
    @State private var phoneHaptics: PhoneHaptics
    @State private var feel: FeelController
    /// The pad `feel` is rumbling, so a pad change is noticed once.
    @State private var feelPad: ObjectIdentifier?
    @Query private var feelRecords: [FeelSettings]
    /// Tilt to aim with the phone, and a real controller's motion for the PC.
    @State private var motion = MotionHub()
    @State private var padMotion = ControllerMotionReporter()
    @Environment(\.scenePhase) private var scenePhase
    /// The address Sunshine answered on, tried first when looking for Pocket Rig Helper again.
    @State private var streamAddress: String?
    /// Waiting to close the screen after Sleep or Restart; cancelled when the screen is left.
    @State private var closeTask: Task<Void, Never>?
    @State private var helperRefreshTask: Task<Void, Never>?
    /// Overheat protection and away-from-home quality.
    @State private var thermal = ThermalWatcher()
    @State private var network = NetworkWatcher()
    @State private var heat = HeatGovernor()
    @State private var quality = QualityContext()
    @State private var banners = StreamBannerModel()
    /// The floating window; nil where it isn't supported.
    @State private var pip: StreamPictureInPicture?
    /// The app left the screen without picture in picture, so the stream was stopped; it starts again on return.
    @State private var pausedForBackground = false
    @State private var backgroundTask: Task<Void, Never>?
    /// Pause and resume run in order, so a quick return waits for the stop to finish.
    @State private var lifecycle = StreamLifecycleQueue()
    /// The screen was left (Close, or "Resume last game" opened something else). Late callbacks do nothing.
    @State private var hasLeft = false
    /// The scene phase, kept as state. The picture-in-picture, resize and resume callbacks outlive this view
    /// value; an `@Environment` value read inside them is the one from when they were made, this is current.
    @State private var currentPhase: ScenePhase = .active

    init(host: Host, appID: Int, initialPose: Pose) {
        self.host = host
        self.appID = appID
        _deck = State(initialValue: DeckModel(gamepad: GamepadInput(sender: MoonlightControllerSender()),
                                              pointer: MoonlightPointerSender(),
                                              buttons: DefaultLayouts.buttons(for: initialPose)))
        let phone = PhoneHaptics()
        _phoneHaptics = State(initialValue: phone)
        _feel = State(initialValue: FeelController(phone: phone))
    }

    private var isStreaming: Bool { session?.state == .streaming }
    /// Reconnecting for a new size or quality, or a failed reconnect waiting to retry.
    private var isRefitting: Bool { resizer?.hasUnfinishedRefit ?? false }

    /// The player is looking at the full stream screen: the app is in front and not in the floating window.
    private var isWatchingFullScreen: Bool {
        StreamBackgroundRule.canReconnect(appIsActive: currentPhase == .active, inPictureInPicture: pip?.isActive == true)
    }

    /// Per-game layouts are saved under this key.
    private var gameKey: String { ControlLayout.gameKey(serverUniqueID: host.serverUniqueID, appID: appID) }

    /// The position the screen is laid out for (a wide closed phone streams sideways).
    private var layoutPose: Pose { poses.pose.streamingPose(in: poses.windowSize).layoutPose }

    /// Vibration and tilt settings; defaults until the settings sheet first saves them.
    private var feelSettings: FeelSnapshot { feelRecords.first?.snapshot ?? FeelSnapshot() }

    var body: some View {
        screen
            .onChange(of: thermal.state) { updateHeat() }
            .onChange(of: network.snapshot) { updateNetwork() }
            // Thermal changes are announced, but look again now and then so a cool-down is noticed.
            .task(id: isStreaming) {
                guard isStreaming else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    thermal.refresh()
                    updateHeat()
                }
            }
    }

    private var screen: some View {
        StreamLayoutView(deck: deck, onClose: close, onGameAreaChange: gameAreaChanged) {
            videoArea
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .task(id: gameArea == .zero) {
            // Wait for the first layout pass so the first stream already has the right size.
            if gameArea != .zero { await start() }
        }
        .onAppear(perform: configureDeck)
        // Here, not on the Quick menu, so a PC control or replay that finishes on another deck tab is still felt.
        .sensoryFeedback(trigger: deck.resultFeedback) { _, new in
            guard feelSettings.strength.tapIntensity != nil, let new else { return nil }
            return new.succeeded ? .success : .error
        }
        .onChange(of: layoutPose, initial: true) { applyLayout() }
        .fullScreenCover(isPresented: $editing, onDismiss: applyLayout) {
            LayoutEditorView(pose: layoutPose, gameKey: gameKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshController() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshController() }
        .onChange(of: session?.state) { _, state in stateChanged(state) }
        .onChange(of: monitor.hasController) { refreshController() }
        .onChange(of: monitor.currentID) { updateFeelController() }
        .onChange(of: scenePhase) { scenePhaseChanged() }
        // "Resume last game" for the game already on screen: bring it back out of the floating window.
        .onChange(of: model.showStreamRequests) { pip?.stop() }
        // While streaming and on screen, look at the Helper now and then, so what the Quick menu offers stays true.
        .task(id: scenePhase == .active && isStreaming) {
            guard scenePhase == .active, isStreaming else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await refreshHelperStatus()
            }
        }
        // Tilt must not aim in the game while the player is editing buttons.
        .onChange(of: editing) { updateMotionLive() }
        .onChange(of: feelSettings) { _, settings in
            feel.apply(settings)
            motion.apply(settings)
            session?.setSoundTap(settings.listensToSound)
        }
        .onDisappear {
            // The editor covers this screen; that is not leaving the stream.
            if !editing { leave() }
        }
        // Last, so the editor's full-screen cover (and the combo recorder in it) gets it too.
        .environment(\.hapticsStrength, feelSettings.strength)
    }

    // MARK: Pieces

    private var videoArea: some View {
        ZStack {
            Color.black
            if let session { StreamVideoView(renderer: session.video) }
            statusOverlay
        }
        .overlay(alignment: .bottom) { StreamBannerOverlay(model: banners) }
    }

    @ViewBuilder private var statusOverlay: some View {
        if let connectError {
            failure(title: "Can't connect", message: connectError)
        } else if pip?.isActive == true {
            // Started from the Quick menu with the app open: the picture is in the window, not here.
            FloatingWindowNotice { pip?.stop() }
        } else if pausedForBackground {
            progress("Reconnecting…")
        } else {
            let state = session?.state
            if isRefitting, state != .streaming {
                progress(StreamStatusText.refitMessage(for: resizer?.reason ?? .resize))
            } else {
                switch state {
                case .failed?:
                    failure(title: "Stream stopped", message: StreamStatusText.message(for: state), canRetry: true)
                case .ended?:
                    failure(title: "Stream ended", message: nil)
                default:
                    if let text = StreamStatusText.message(for: state) { progress(text) }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(.white)
            Text(text).font(.headline).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private func failure(title: String, message: String?, canRetry: Bool = false) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 12) {
                if canRetry {
                    Button("Try again") { resizer?.tryAgain() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                if canRetry {
                    Button("Back") { close() }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button("Back") { close() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    // MARK: Deck

    private func configureDeck() {
        currentPhase = scenePhase   // the real phase, not the default, before anything reads it
        thermal.start()
        network.start()
        feel.apply(feelSettings)
        motion.onStick = { stick in
            // With a controller in hand, tilt goes onto its right stick; otherwise onto the touch pad's.
            if monitor.current != nil { monitor.setGyroStick(stick) } else { deck.gamepad.setGyroStick(stick) }
        }
        motion.onMouse = { dx, dy in deck.pointer.send(.move(dx: dx, dy: dy)) }
        motion.apply(feelSettings)
        refreshController()
        deck.statsProvider = { session?.statsSnapshot() }
        deck.onDisconnect = { close() }
        deck.onEditButtons = { editing = true }
        deck.helper = model.helperStatus(for: host)
        deck.hasSavedWakeAddress = host.macAddress.map(WakeOnLAN.isValidMAC) == true
        deck.onPCControl = { control in await runPCControl(control) }
        // A refused action may mean the Helper's list or Steam's state changed; look again.
        deck.onPCControlFailed = {
            helperRefreshTask?.cancel()
            helperRefreshTask = Task { await refreshHelperStatus() }
        }
        // `-pr.deckTab <tab>` (DEBUG): open on that tab, for hands-free checks against a real PC.
        if let tab = DebugLaunchOptions.text("deckTab").flatMap(DeckTab.init(rawValue:)) { deck.tab = tab }
        deck.onPhysicalTap = { monitor.tap($0) }
        deck.onScreenshot = {
            guard let video = session?.video else { return .nothingToSave }
            return await FrameCapture.saveCurrentFrame(from: video)
        }
        deck.onSaveReplay = {
            guard let video = session?.video else { return .nothingToSave }
            return await ReplaySaver.save(video.replay)
        }
        deck.onPictureInPicture = { pip?.start() ?? false }
    }

    private func applyLayout() {
        let layout = LayoutStore(context: context).resolve(pose: layoutPose, gameKey: gameKey)
        deck.buttons = layout.buttons
        deck.style = layout.style
    }

    /// Updates the deck only on a real connect or disconnect, never because of a reconnect.
    private func refreshController() {
        let wanted = ControllerPresence.resolve(
            current: deck.hasPhysicalController, isStreaming: isStreaming,
            monitorHasController: monitor.hasController,
            padConnected: PhysicalControllerMonitor.isPadConnected(), isReconnecting: isRefitting)
        guard wanted != deck.hasPhysicalController else { return }
        deck.controllerChanged(wanted)
        guard isStreaming else { return }
        // Touch and physical pads share controller slot 0; only one is ever live.
        if wanted { deck.gamepad.releaseAll() } else { deck.gamepad.announceArrival() }
    }

    /// Rumble follows the pad in use: on the pad when one is connected, otherwise on the phone.
    private func updateFeelController() {
        let pad = monitor.current
        padMotion.attach(pad)
        let id = pad.map(ObjectIdentifier.init)
        guard id != feelPad else { return }
        feelPad = id
        // A pad with no working motors gives nil here, so the phone keeps vibrating for it.
        feel.controllerChanged(attached: pad != nil, rumble: pad.flatMap { ControllerHaptics(controller: $0) })
    }

    // MARK: Sizing

    private var preferences: StreamPreferences { StreamPreferences.current(in: context) }

    /// A warm or hot phone streams at 720p at most.
    private func pixelSize(for area: CGSize) -> PixelSize {
        StreamSizing.pixelSize(points: area, scale: displayScale,
                               cap: StreamQualityRules.cap(preferences.resolutionCap, heat: quality.heat),
                               maxPixels: maxPixels)
    }

    /// The user's Quality choices, held back for heat and for being away from home.
    private func settings(for size: PixelSize) -> StreamSettings {
        StreamQualityRules.adjust(
            preferences.streamSettings(size: size, screenMaxFPS: ScreenInfo.maximumFramesPerSecond,
                                       audioEnabled: !DebugLaunchOptions.noAudio),
            for: quality)
    }

    private func gameAreaChanged(_ area: CGSize) {
        gameArea = area
        guard area != .zero else { return }
        resizer?.propose(pixelSize(for: area))
    }

    private func makeResizer(for session: StreamSession, startSize: PixelSize) -> StreamResizeController {
        StreamResizeController(
            session: session, startSize: startSize,
            settingsFor: { settings(for: $0) },
            willReconnect: {
                pip?.setAllowed(false)   // a stream between two connections doesn't float; allowed again once live
                deck.isLive = false
                deck.gamepad.releaseAll()
                feel.stopAll()
                motion.setLive(false)
                padMotion.reset()
                monitor.stop()   // started again (with a fresh arrival) once the new stream is live
            },
            didReconnect: { refreshController() },   // catches a pad really plugged or unplugged meanwhile
            // Never in the background or the floating window; it waits, and `resume()` runs it later.
            canReconnect: { isWatchingFullScreen })
    }

    // MARK: Lifecycle

    private func start() async {
        guard session == nil, connectError == nil else { return }
        do {
            let connection = try await model.connect(host)
            guard !Task.isCancelled else { return }
            maxPixels = connection.info.maxLumaPixelsHEVC > 0 ? connection.info.maxLumaPixelsHEVC : nil
            // The first stream already respects the phone's heat and the network it's on.
            _ = heat.update(thermal.state, enabled: preferences.heatProtection, now: .now)
            quality = QualityContext(
                heat: heat.step,
                awayLimitKbps: StreamQualityRules.awayLimit(network: network.snapshot, streamAddress: connection.address,
                                                            preference: preferences.awayBitrateKbps))
            let size = pixelSize(for: gameArea)
            let session = StreamSession(api: connection.api, serverInfo: connection.info,
                                        address: connection.address, appID: appID, settings: settings(for: size))
            self.session = session
            let pip = StreamPictureInPicture(layer: session.video.displayLayer)
            pip?.onStart = { pictureInPictureStarted() }
            pip?.onStop = { restored in pictureInPictureStopped(restored: restored) }
            self.pip = pip
            deck.canPictureInPicture = pip != nil
            session.onHostFeedback = { feedback in
                // In the floating window the phone doesn't rumble or report motion.
                if pip?.isActive == true { return }
                if case .motionRequest(let controller, let type, let rate) = feedback {
                    // Only a real controller with sensors tells the PC it has them.
                    if controller == 0 { padMotion.hostRequested(type: type, rateHz: rate) }
                    return
                }
                feel.handle(feedback)
            }
            session.setSoundTap(feelSettings.listensToSound)
            resizer = makeResizer(for: session, startSize: size)
            // Looks for Pocket Rig Helper alongside the stream, where Sunshine just answered.
            streamAddress = connection.address
            deck.streamAddress = connection.address
            helperRefreshTask = Task { await refreshHelperStatus() }
            await session.start()
        } catch HostError.notPaired {
            guard !Task.isCancelled else { return }
            model.replaceTop(.stream(serverUniqueID: host.serverUniqueID, appID: appID),
                             with: .pair(serverUniqueID: host.serverUniqueID))
        } catch {
            guard !Task.isCancelled else { return }
            connectError = AppModel.message(for: error)
        }
    }

    private func stateChanged(_ state: StreamState?) {
        guard !hasLeft else { return }
        UIApplication.shared.isIdleTimerDisabled = state == .streaming
        switch state {
        case .streaming?:
            if !hasStreamed {
                hasStreamed = true
                if feelSettings.strength.tapIntensity != nil {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                if isWatchingFullScreen, let banner = StreamBanner.heat(from: .normal, to: quality.heat) {
                    banners.show(banner)
                }
            }
            // Once per launch; waits until someone can read it (it may come after a resume).
            warnAboutDataIfNeeded()
            pausedForBackground = false
            // In the floating window the stream plays, but the controls stay off until the app is back.
            guard pip?.isActive != true else {
                resizer?.sessionStateChanged(state)
                return
            }
            deck.isLive = true
            monitor.start()
            updateMotionLive()
            refreshController()
            if !monitor.hasController { deck.gamepad.announceArrival() }
            resizer?.sessionStateChanged(state)   // the screen may have changed again while this stream came up
        case .failed?, .ended?:
            if case .failed? = state { pausedForBackground = false }   // show the real problem, with Try again
            pip?.setAllowed(false)
            pip?.stop()   // a lost stream must not leave a frozen window (does nothing when it isn't open)
            deck.isLive = false
            deck.gamepad.releaseAll()
            feel.stopAll()
            motion.setLive(false)
            padMotion.reset()
            monitor.stop()
            refreshController()
            if case .ended? = state,
               StreamBackgroundRule.shouldRestartAfterEnd(pausedForBackground: pausedForBackground,
                                                          appIsActive: currentPhase == .active,
                                                          resumeScheduled: lifecycle.pendingResumes > 0) {
                applyBackground(.resume)
            }
        default:
            break
        }
    }

    private func close() {
        if let intensity = feelSettings.strength.tapIntensity {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: intensity)
        }
        if !model.path.isEmpty { model.path.removeLast() }
    }

    /// Looks for Pocket Rig Helper again. `AppModel` keeps only the newest answer and tolerates one missed look.
    private func refreshHelperStatus() async {
        let status = await model.refreshHelper(host, preferredAddress: streamAddress)
        guard !Task.isCancelled else { return }
        deck.helper = status
        // The Helper check may have just saved the PC's network-card address.
        deck.hasSavedWakeAddress = host.macAddress.map(WakeOnLAN.isValidMAC) == true
    }

    // MARK: Heat and data

    /// Overheat protection: lower or restore quality as the phone heats up and cools down.
    private func updateHeat() {
        let old = heat.step
        let enabled = preferences.heatProtection
        guard let step = heat.update(thermal.state, enabled: enabled, now: .now) else { return }
        // Turning the switch off resets quietly; only a real thermal change gets a notice, and only where it
        // can be read (not in the background or the floating window; it isn't saved for later).
        if hasStreamed, enabled, isWatchingFullScreen, let banner = StreamBanner.heat(from: old, to: step) {
            banners.show(banner)
        }
        var next = quality
        next.heat = step
        applyQuality(next)
    }

    /// Away from home: hold the data back on mobile data, Low Data Mode or Tailscale.
    private func updateNetwork() {
        var next = quality
        next.awayLimitKbps = StreamQualityRules.awayLimit(network: network.snapshot, streamAddress: streamAddress,
                                                          preference: preferences.awayBitrateKbps)
        applyQuality(next)
        warnAboutDataIfNeeded()
    }

    /// Reconnects only when the stream would really change.
    private func applyQuality(_ next: QualityContext) {
        guard next != quality else { return }
        quality = next
        guard gameArea != .zero, let session, let resizer else { return }
        let size = pixelSize(for: gameArea)
        guard settings(for: size) != session.settings else { return }
        resizer.qualityChanged(size: size)
    }

    /// Once per app launch: how much mobile data an hour of this stream uses. Only for real mobile data
    /// (or a hotspot); Low Data Mode and Tailscale still lower the quality, quietly. Not used up while nobody
    /// can see it: it is tried again when the app comes back and when the floating window closes.
    private func warnAboutDataIfNeeded() {
        guard hasStreamed, isStreaming, network.snapshot.isExpensive, !model.hasShownDataWarning, gameArea != .zero,
              StreamBackgroundRule.canShowNotice(appIsActive: currentPhase == .active,
                                                 inPictureInPicture: pip?.isActive == true) else { return }
        model.hasShownDataWarning = true
        banners.showAfterCurrent(.dataWarning(kbps: settings(for: pixelSize(for: gameArea)).bitrateKbps))
    }

    /// Runs a PC control through the Helper. Sleep and Restart then leave the stream before the PC goes away,
    /// unless the user already left this screen. A cancelled call (screen left mid-action) says nothing.
    private func runPCControl(_ control: PCControl) async -> PCControlResult {
        guard let client = model.helperClient(for: host) else {
            return .helperNotAnswering
        }
        do {
            try await client.perform(control)
        } catch is CancellationError {
            return PCControlResult(message: "", succeeded: false)
        } catch {
            return PCControlResult(message: HelperError.message(for: error), succeeded: false)
        }
        if control.endsStream {
            let route = Route.stream(serverUniqueID: host.serverUniqueID, appID: appID)
            closeTask?.cancel()
            closeTask = Task {
                try? await Task.sleep(for: PCControl.streamCloseDelay)
                guard !Task.isCancelled, model.path.last == route else { return }
                close()
            }
        }
        return PCControlResult(message: control.doneMessage, succeeded: true)
    }

    /// Tilt runs only while a stream is live, the app is on screen, the button editor is closed and the
    /// stream isn't in the floating window. The floating window may start by itself only while live.
    private func updateMotionLive() {
        let live = session?.state == .streaming
        motion.setLive(currentPhase == .active && !editing && pip?.isActive != true && live)
        pip?.setAllowed(!editing && live)
    }

    // MARK: Background and picture in picture

    /// Starting or playing, or between two connections of a refit; a paused, ended or failed stream isn't.
    private var isRunning: Bool {
        StreamBackgroundRule.isRunning(session?.state, refitUnderway: resizer?.hasUnfinishedRefit == true)
    }

    private func scenePhaseChanged() {
        let phase = scenePhase
        currentPhase = phase
        updateMotionLive()
        backgroundTask?.cancel()
        guard phase == .background else {
            let action = StreamBackgroundRule.onPhase(phase, isRunning: isRunning,
                                                      inPictureInPicture: pip?.isActive == true,
                                                      pausedForBackground: pausedForBackground)
            applyBackground(action)
            // Back in front with the stream still going: a quality change or retry that waited runs now,
            // and a data warning that couldn't be seen shows. (A paused stream starts with both settled.)
            if phase == .active, !pausedForBackground {
                resizer?.resume()
                warnAboutDataIfNeeded()
            }
            return
        }
        // Swiping home starts picture in picture a moment after the app leaves; decide after that.
        backgroundTask = Task {
            try? await Task.sleep(for: StreamBackgroundRule.graceDelay)
            guard !Task.isCancelled else { return }
            // The window can be slower than the grace period; wait once more if it is on its way.
            if pip?.isActive != true,
               StreamBackgroundRule.shouldWaitForLateStart(pictureInPicturePossible: pip?.couldStartAutomatically == true,
                                                           autoStartAllowed: true, alreadyExtended: false) {
                try? await Task.sleep(for: StreamBackgroundRule.graceDelay)
                guard !Task.isCancelled else { return }
            }
            applyBackground(StreamBackgroundRule.onPhase(.background, isRunning: isRunning,
                                                         inPictureInPicture: pip?.isActive == true,
                                                         pausedForBackground: pausedForBackground))
        }
    }

    private func applyBackground(_ action: StreamBackgroundAction) {
        guard !hasLeft, let session else { return }
        switch action {
        case .nothing:
            break
        case .pause:
            pip?.setAllowed(false)   // no late floating window for a stream that is stopping
            pausedForBackground = true
            lifecycle.pause { await session.stop() }
        case .resume:
            // Stays "paused" (showing "Reconnecting…") until the stream is back or fails.
            // Waits for any stop still running, then starts only if the app is still in front.
            lifecycle.resume(shouldRun: { pausedForBackground && currentPhase == .active }) {
                // Start with what is wanted now (heat, network, size), so it doesn't reconnect a second time.
                if gameArea != .zero { resizer?.streamWillRestart(at: pixelSize(for: gameArea)) }
                await session.start()
            }
        case .resumeInput:
            pictureInPictureEnded()
        }
    }

    /// The floating window opened: the controls, rumble, tilt and sound-driven vibration go quiet.
    private func pictureInPictureStarted() {
        deck.isLive = false
        deck.gamepad.releaseAll()
        feel.stopAll()
        motion.setLive(false)
        padMotion.reset()
        monitor.stop()
        session?.setSoundTap(false)
    }

    private func pictureInPictureStopped(restored: Bool) {
        applyBackground(StreamBackgroundRule.onPictureInPictureStop(
            restored: restored, appIsActive: currentPhase == .active, isRunning: isRunning,
            appIsInactive: currentPhase == .inactive))
    }

    /// Back from the floating window: everything picture in picture turned off comes back on.
    private func pictureInPictureEnded() {
        guard !hasLeft else { return }
        session?.setSoundTap(feelSettings.listensToSound)
        // A quality change or retry that waited for the window to close runs now (if the app is in front).
        resizer?.resume()
        warnAboutDataIfNeeded()
        guard isStreaming else { return }
        deck.isLive = true
        monitor.start()
        updateMotionLive()
        refreshController()
        if !monitor.hasController { deck.gamepad.announceArrival() }
    }

    private func leave() {
        hasLeft = true
        // AVKit's "did stop" can arrive after the screen is gone; it must not turn anything back on.
        // Clearing these also lets go of this screen's state, which the window's callbacks held on to.
        pip?.onStart = {}
        pip?.onStop = { _ in }
        closeTask?.cancel()
        helperRefreshTask?.cancel()
        backgroundTask?.cancel()
        pip?.setAllowed(false)
        pip?.stop()
        thermal.stop()
        network.stop()
        banners.clear()
        deck.stopPCControl()
        resizer?.cancel()
        deck.gamepad.releaseAll()
        // Rumble still queued from the PC must not restart the motor after we close it.
        session?.onHostFeedback = { _ in }
        feel.stopAll()
        motion.setLive(false)
        padMotion.reset()
        feelPad = nil
        feel.controllerChanged(attached: false, rumble: nil)   // closes the pad's motors
        phoneHaptics.shutdown()
        monitor.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if let session { lifecycle.close { await session.stop() } }
    }
}
