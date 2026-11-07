import SwiftData
import SwiftUI

/// Deck tab: one-tap actions for the game and the PC.
struct QuickMenuTab: View {
    @Bindable var model: DeckModel
    @Environment(\.modelContext) private var context
    /// `-pr.openQuality YES` (DEBUG): open Stream quality straight away.
    @State private var showsQuality = DebugLaunchOptions.flag("openQuality")
    @State private var showsFeel = false
    @State private var notice: Notice?
    @State private var noticeTask: Task<Void, Never>?
    @State private var savingScreenshot = false
    /// The PC control waiting for "are you sure?". `-pr.openPCControl <action>` (DEBUG only) opens one at
    /// launch; the values are the Helper's names: restart-steam, close-game, sleep, restart, lock.
    @State private var pendingControl: PCControl? = DebugLaunchOptions.text("openPCControl").flatMap(PCControl.init(rawValue:))
    /// Bumped on each tap of a tile that has no feedback of its own, for a light haptic.
    @State private var taps = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hapticsStrength) private var hapticsStrength
    /// Grows with the text, so a long word like "Screenshot" always fits on one line of its tile
    /// (fewer columns at big sizes instead of words broken mid-way).
    @ScaledMetric(relativeTo: .subheadline) private var tileMinimum: CGFloat = 120

    /// The line that slides up after a screenshot or a PC control.
    private struct Notice: Equatable {
        let id = UUID()
        let message: String
        let succeeded: Bool

        var symbol: String { succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }

        init(_ screenshot: ScreenshotResult) {
            message = screenshot.message
            succeeded = screenshot == .saved
        }

        init(_ notice: PCNotice) {
            message = notice.message
            succeeded = notice.succeeded
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: tileMinimum), spacing: 8)] }
    private var titleLines: Int { typeSize.isAccessibilitySize ? 3 : 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actionTiles
                pcControls
            }
            .padding(16)
        }
        // The stream screen draws under the home indicator, so leave room to scroll the last row clear of it.
        .contentMargins(.bottom, 40, for: .scrollContent)
        .overlay(alignment: .bottom) { noticeView }
        .sensoryFeedback(trigger: taps) { _, _ in tapFeedback }
        .sheet(isPresented: $showsQuality) {
            StreamQualitySheet(preferences: StreamPreferences.current(in: context),
                               screenMaxFPS: ScreenInfo.maximumFramesPerSecond)
        }
        .sheet(isPresented: $showsFeel) {
            FeelSettingsSheet(settings: FeelSettings.current(in: context))
        }
        .sensoryFeedback(trigger: notice) { _, new in
            guard hapticsStrength.tapIntensity != nil, let new else { return nil }
            return new.succeeded ? .success : .error
        }
        // An alert, not a dialog: it always shows Cancel, scrolls long text, and VoiceOver can reach it.
        .alert(
            pendingControl?.confirmTitle ?? "",
            isPresented: Binding(get: { pendingControl != nil }, set: { if !$0 { pendingControl = nil } }),
            presenting: pendingControl
        ) { control in
            Button(control.confirmButton, role: control.isDestructive ? .destructive : nil) { model.runPCControl(control) }
            Button("Cancel", role: .cancel) {}
        } message: { control in
            Text(control.confirmMessage(canWake: model.canWakeAfterSleep))
        }
        // The PC control / replay result haptic is on the stream screen, so it comes on any deck tab.
        // The PC control keeps running (and its result waits) while another tab shows; this tab just renders it.
        .onAppear { model.restartNoticeTimer() }
        .onDisappear { noticeTask?.cancel() }
        .task { await debugAutoSaveReplay() }
    }

    /// The light tap on a tile, at the user's strength (none when vibration is off).
    private var tapFeedback: SensoryFeedback? {
        hapticsStrength.tapIntensity.map { SensoryFeedback.impact(weight: .light, intensity: Double($0)) }
    }

    private var actionTiles: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            tile("Edit buttons", "hand.tap.fill", needsStream: true) { model.onEditButtons() }
            tile("Steam button", "house.fill", needsStream: true) { model.tapSteamButton() }
            // Screenshot and Disconnect give their own feedback (saved/failed, and the close tap).
            tile("Screenshot", "camera.fill", needsStream: true, haptic: false) { takeScreenshot() }
            // A light tap on start; the saved / failed notice gives its own haptic.
            tile("Save last 30 seconds", "gobackward.30", needsStream: true,
                 busy: model.isSavingReplay, busyText: "Saving…", ready: model.replayReady) { model.saveReplay() }
            if model.canPictureInPicture {
                tile("Picture in picture", "pip.enter", needsStream: true) { model.startPictureInPicture() }
            }
            tile("Volume down", "speaker.minus.fill", needsStream: true) { model.pointer.tapKey(.volumeDown) }
            tile("Volume up", "speaker.plus.fill", needsStream: true) { model.pointer.tapKey(.volumeUp) }
            tile("Mute", "speaker.slash.fill", needsStream: true) { model.pointer.tapKey(.volumeMute) }
            tile("Quality", "slider.horizontal.3", needsStream: false) { showsQuality = true }
            tile("Vibration & aiming", "iphone.radiowaves.left.and.right", needsStream: false) { showsFeel = true }
            tile("Disconnect", "xmark.circle.fill", needsStream: false, role: .destructive, haptic: false) {
                model.onDisconnect()
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, needsStream: Bool, role: ButtonRole? = nil,
                      haptic: Bool = true, busy: Bool = false, busyText: String = "Working…", ready: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(role: role) {
            if haptic { taps += 1 }
            action()
        } label: {
            tileLabel(title, symbol: symbol, busy: busy, busyText: busyText)
        }
        .buttonStyle(.glass)
        .disabled((needsStream && !model.isLive) || busy || !ready)
        .accessibilityLabel(busy ? "\(title). \(busyText)" : title)
        .accessibilityHint(ready ? "" : "Available a moment after the stream starts")
    }

    private func tileLabel(_ title: String, symbol: String, busy: Bool, busyText: String = "Working…") -> some View {
        VStack(spacing: 8) {
            if busy {
                ProgressView()
            } else {
                Image(systemName: symbol).font(.title2)
            }
            Text(busy ? busyText : title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(titleLines)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
    }

    /// Steam and power controls through Pocket Rig Helper. Each works only when the Helper lists it, and
    /// each asks first.
    private var pcControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PC controls")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(PCControl.allCases) { pcTile($0) }
            }
            if let note = PCControl.unavailableNote(for: model.helper) {
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pcTile(_ control: PCControl) -> some View {
        let available = model.helper.can(control.capability)
        let busy = model.runningControl == control
        return Button {
            taps += 1
            pendingControl = control
        } label: {
            tileLabel(control.title, symbol: control.symbol, busy: busy)
        }
        .buttonStyle(.glass)
        .disabled(!available || model.runningControl != nil)
        .accessibilityLabel(busy ? "\(control.title). Working." : control.title)
        .accessibilityHint(hint(for: control, available: available))
    }

    private func hint(for control: PCControl, available: Bool) -> String {
        if available { return model.runningControl == nil ? "Asks before it does anything." : "Another PC control is running." }
        return PCControl.unavailableNote(for: model.helper) ?? "Not available on this PC right now."
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = notice ?? model.pcNotice.map(Notice.init) {
            QuickMenuNoticeLabel(message: notice.message, symbol: notice.symbol)
                .padding(16)
                // Taps reach the tiles under it, so nothing is out of reach while it shows.
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func takeScreenshot() {
        guard !savingScreenshot else { return }
        savingScreenshot = true
        Task {
            let result = await model.onScreenshot()
            savingScreenshot = false
            show(Notice(result))
        }
    }

    /// `-pr.saveReplayAfter <seconds>` (DEBUG): saves a replay that long after the Quick menu appears,
    /// for hands-free checks against a real PC.
    private func debugAutoSaveReplay() async {
        guard !model.debugReplayFired, let seconds = DebugLaunchOptions.text("saveReplayAfter").flatMap(Double.init) else { return }
        try? await Task.sleep(for: .seconds(seconds))
        // Wait for the tile to be ready, then fire once per launch.
        while !model.replayReady {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled, !model.debugReplayFired else { return }
        model.debugReplayFired = true
        model.saveReplay()
    }

    private func show(_ new: Notice) {
        noticeTask?.cancel()
        AccessibilityNotification.Announcement(new.message).post()
        withAnimation { notice = new }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { notice = nil }
        }
    }
}

/// The capsule that slides up over the Quick menu's tiles after a screenshot, PC control or replay save.
/// Its text stops growing at the largest non-accessibility size (like the stream's own notes), so on a
/// small phone it stays a short strip instead of hiding a couple of tiles. VoiceOver reads it out anyway.
struct QuickMenuNoticeLabel: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
