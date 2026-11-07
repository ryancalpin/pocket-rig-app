import SwiftData
import SwiftUI

#if DEBUG
/// `-pr.streamPreview YES`: the stream screen with a stand-in picture instead of a PC, for checking every
/// pose and deck tab on the simulator. `-pr.deckTab <gamepad|trackpad|quickMenu|stats>` picks the tab.
struct StreamPreviewScreen: View {
    @Environment(PoseMonitor.self) private var poses

    var body: some View {
        // Build the deck from the current pose, so the first frame already has the right buttons.
        PreviewBody(initialPose: poses.pose.streamingPose(in: poses.windowSize).layoutPose)
    }
}

private struct PreviewBody: View {
    @Environment(PoseMonitor.self) private var poses
    @Environment(\.modelContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var deck: DeckModel
    @State private var gameArea: CGSize = .zero
    @State private var editing = false
    @State private var showsFeel = false
    @Query private var feelRecords: [FeelSettings]
    @State private var banners = StreamBannerModel()
    /// `-pr.pipActiveDemo YES`: as if the stream were playing in the floating window (the simulator can't open one).
    @State private var floating = DebugLaunchOptions.flag("pipActiveDemo")

    private var layoutPose: Pose { poses.pose.streamingPose(in: poses.windowSize).layoutPose }

    init(initialPose: Pose) {
        _deck = State(initialValue: DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()),
                                              buttons: DefaultLayouts.buttons(for: initialPose)))
    }

    var body: some View {
        StreamLayoutView(deck: deck, onClose: {}, onGameAreaChange: { gameArea = $0 }) {
            standInPicture
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: configure)
        .onChange(of: layoutPose, initial: true) { applyLayout() }
        .fullScreenCover(isPresented: $editing, onDismiss: applyLayout) {
            LayoutEditorView(pose: layoutPose, gameKey: "PREVIEW/1")
        }
        .sheet(isPresented: $showsFeel) {
            FeelSettingsSheet(settings: FeelSettings.current(in: context))
        }
        // Last, so the editor's full-screen cover gets it too.
        .environment(\.hapticsStrength, feelRecords.first?.hapticsStrength ?? .medium)
    }

    private var gameAreaWindow: CGSize { poses.windowSize }

    private var pixels: PixelSize {
        StreamSizing.pixelSize(points: gameArea, scale: displayScale,
                               cap: StreamPreferences.current(in: context).resolutionCap)
    }

    private var standInPicture: some View {
        LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "play.tv.fill").font(.largeTitle).accessibilityHidden(true)
                    Text("Stream size \(pixels.title)").font(.headline)
                    Text(poses.pose.streamingPose(in: gameAreaWindow).title).font(.subheadline)
                }
                .foregroundStyle(.white)
            }
            .overlay {
                if floating {
                    ZStack {
                        Color.black
                        FloatingWindowNotice { setFloating(false) }
                    }
                }
            }
            .overlay(alignment: .bottom) { StreamBannerOverlay(model: banners) }
    }

    /// The controls go quiet while "floating", as on a real stream.
    private func setFloating(_ on: Bool) {
        floating = on
        deck.isLive = !on
    }

    private func applyLayout() {
        let layout = LayoutStore(context: context).resolve(pose: layoutPose, gameKey: "PREVIEW/1")
        deck.buttons = DebugLaunchOptions.flag("specialDemo") ? SpecialButtonDemo.apply(to: layout.buttons) : layout.buttons
        deck.style = layout.style
    }

    private func configure() {
        deck.isLive = true
        deck.controllerChanged(PhysicalControllerMonitor.isPadConnected())
        if let tab = DebugLaunchOptions.text("deckTab").flatMap(DeckTab.init(rawValue:)) { deck.tab = tab }
        deck.statsProvider = { .demo }
        deck.onEditButtons = { editing = true }
        // `-pr.helperDemo YES`: the PC controls light up and pretend to work; without it they show "no Helper".
        deck.helper = HelperDemo.isOn ? .present(HelperDemo.info) : .absent
        deck.hasSavedWakeAddress = HelperDemo.isOn
        deck.onPCControl = { control in
            try? await Task.sleep(for: .milliseconds(400))
            return PCControlResult(message: control.doneMessage, succeeded: true)
        }
        // The stand-in picture has no video to save; pretend, so the tile and its notice can be checked.
        deck.onSaveReplay = {
            try? await Task.sleep(for: .milliseconds(600))
            return .saved(seconds: 30)
        }
        // `-pr.thermalDemo serious|critical` and `-pr.networkDemo cellular`: show the notice a real
        // stream would, held for a minute so every pose's screenshot has it.
        if let thermal = ThermalWatcher.demoFromLaunchOptions() {
            var governor = HeatGovernor()
            if let step = governor.update(thermal, enabled: true, now: .now),
               let banner = StreamBanner.heat(from: .normal, to: step) {
                banners.show(banner, for: .seconds(60))
            }
        } else if NetworkWatcher.demoFromLaunchOptions()?.isExpensive == true {
            let prefs = StreamPreferences.current(in: context)
            let kbps = min(prefs.bitrateKbps, prefs.awayBitrateKbps == 0 ? prefs.bitrateKbps : prefs.awayBitrateKbps)
            banners.show(.dataWarning(kbps: kbps), for: .seconds(60))
        }
        // `-pr.pipDemo YES`: show the Picture in picture tile (the simulator can't open the window itself).
        // The tile then pretends to open the window.
        if DebugLaunchOptions.flag("pipDemo") || floating { deck.canPictureInPicture = true }
        deck.onPictureInPicture = {
            setFloating(true)
            return true
        }
        if floating { setFloating(true) }
        // `-pr.openEditor YES`: open the editor straight away.
        if DebugLaunchOptions.flag("openEditor") { editing = true }
        // `-pr.openFeelSettings YES`: open "Vibration & aiming" straight away.
        if DebugLaunchOptions.flag("openFeelSettings") { showsFeel = true }
        // `-pr.fakeController YES`: a controller "connects" a second after launch (handoff check).
        if DebugLaunchOptions.flag("fakeController") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                deck.controllerChanged(true)
            }
        }
        // `-pr.specialDemo YES`: once the pad is up, latch the tap-to-hold button so its lit look shows.
        if DebugLaunchOptions.flag("specialDemo") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard let east = deck.buttons.first(where: { $0.kind == .faceEast }) else { return }
                let binding = SpecialBinding(target: .button(.b), behavior: .toggle)
                deck.gamepad.special(east.id, binding, down: true)
                deck.gamepad.special(east.id, binding, down: false)
            }
        }
    }
}

/// `-pr.specialDemo YES`: A is turbo, B is tap-to-hold, Y plays a short combo.
enum SpecialButtonDemo {
    static func apply(to buttons: [ControlButton]) -> [ControlButton] {
        buttons.map { button in
            var button = button
            switch button.kind {
            case .faceSouth:
                button.behavior = .turbo
            case .faceEast:
                button.behavior = .toggle
            case .faceNorth:
                button.behavior = .macro
                button.macro = Macro(steps: [
                    MacroStep(frame: MacroFrame(buttons: .a), seconds: 0.1),
                    MacroStep(frame: MacroFrame(), seconds: 0.1),
                    MacroStep(frame: MacroFrame(buttons: .b), seconds: 0.1),
                ])
            default:
                break
            }
            return button
        }
    }
}
#endif
