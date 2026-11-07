import Observation
import SwiftUI

/// What the deck shows and does for one stream screen.
@MainActor @Observable
final class DeckModel {
    let gamepad: GamepadInput
    let pointer: any PointerEventSending
    var tab: DeckTab = .gamepad
    /// A physical controller is connected, so the touch buttons step aside.
    private(set) var hasPhysicalController = false
    /// The stream is live. Until then touch controls are dimmed and ignore touches, so nothing reaches the PC early.
    var isLive = false {
        didSet { if oldValue != isLive { liveChanged() } }
    }
    /// The stream has run long enough (1 s) for "Save last 30 seconds" to have something to save.
    private(set) var replayReady = false
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    /// DEBUG `-pr.saveReplayAfter` has fired (once per launch).
    @ObservationIgnored var debugReplayFired = false
    /// How long the stream must be live before the replay tile turns on (shortened in tests).
    @ObservationIgnored var replayReadyDelay: Duration = .seconds(1.2)
    var buttons: [ControlButton]
    var style: ControllerStyle = .xbox
    /// Supplies the Stats tab; nil while there is no stream.
    @ObservationIgnored var statsProvider: @MainActor () -> StatsSnapshot? = { nil }
    @ObservationIgnored var onDisconnect: @MainActor () -> Void = {}
    @ObservationIgnored var onScreenshot: @MainActor () async -> ScreenshotResult = { .nothingToSave }
    /// Saves the last 30 seconds to Photos (set by the stream screen).
    @ObservationIgnored var onSaveReplay: @MainActor () async -> ReplayResult = { .nothingToSave }
    /// "Save last 30 seconds" is writing the clip.
    private(set) var isSavingReplay = false
    @ObservationIgnored private(set) var replayTask: Task<Void, Never>?
    @ObservationIgnored var onEditButtons: @MainActor () -> Void = {}
    /// This phone can show the stream in a floating window (never in the simulator). Set by the stream screen.
    var canPictureInPicture = false
    /// Opens the floating window; false when it can't open yet (set by the stream screen).
    @ObservationIgnored var onPictureInPicture: @MainActor () -> Bool = { false }
    /// Pocket Rig Helper on this PC, for the Quick menu's PC controls.
    var helper: HelperStatus = .unknown
    /// The address the stream runs over. Tailscale reaches a PC that is on, never one that is asleep.
    var streamAddress: String?
    /// This PC has a valid saved network-card address, so Wake PC can be offered later.
    var hasSavedWakeAddress = false
    /// Whether Pocket Rig can wake this PC after a Sleep: the Helper saw a wired card with a cable, the
    /// phone saved its address, and the stream isn't running over Tailscale (which can't wake a sleeper).
    var canWakeAfterSleep: Bool {
        helper.info?.canWake == true && hasSavedWakeAddress
            && !(streamAddress.map(HostAddressResolver.isTailscale) ?? false)
    }
    /// Runs a PC control through the Helper (set by the stream screen).
    @ObservationIgnored var onPCControl: @MainActor (PCControl) async -> PCControlResult = { _ in
        PCControlResult(message: HelperError.unreachable.message, succeeded: false)
    }
    /// Called after a PC control fails, so the stream screen can look at the Helper again (what it
    /// offers or says about Steam may have changed). Set by the stream screen.
    @ObservationIgnored var onPCControlFailed: @MainActor () -> Void = {}
    /// The PC control the Helper is working on. Lives here, not in the Quick menu, so switching deck tabs
    /// mid-action neither loses it nor allows a second one.
    private(set) var runningControl: PCControl?
    /// How the last PC control went; shown on the Quick menu for a few seconds.
    private(set) var pcNotice: PCNotice?
    /// Each result (PC control, replay save, picture in picture) as it arrives, whichever deck tab shows,
    /// so the stream screen gives its success or error haptic. Showing a notice again doesn't change it.
    private(set) var resultFeedback: PCNotice?
    @ObservationIgnored private(set) var controlTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Presses a button on top of the physical pad's state (set by the stream screen).
    @ObservationIgnored var onPhysicalTap: @MainActor (GamepadButtons) -> Void = { _ in }
    /// The deck moved itself to the Quick menu for a controller (and the user hasn't picked a tab since).
    @ObservationIgnored private var autoSwitched = false

    init(gamepad: GamepadInput, pointer: any PointerEventSending = NoOpPointerSender(),
         buttons: [ControlButton] = DefaultLayouts.buttons(for: .upright)) {
        self.gamepad = gamepad
        self.pointer = pointer
        self.buttons = buttons
    }

    /// The Quick menu's Steam button. With a physical pad connected it shares slot 0, so the press goes
    /// through the pad's own state instead of the touch pad's all-zero one.
    func tapSteamButton() {
        if hasPhysicalController { onPhysicalTap(.guide) } else { gamepad.tap(.guide) }
    }

    /// Starts a PC control, unless another one is still running.
    func runPCControl(_ control: PCControl) {
        guard runningControl == nil else { return }
        runningControl = control
        controlTask = Task {
            let result = await onPCControl(control)
            guard !Task.isCancelled else { return }   // the stream screen was left: nothing to tell
            runningControl = nil
            show(PCNotice(result))
            if !result.succeeded { onPCControlFailed() }
        }
    }

    /// Saves the last 30 seconds, unless a save is still running. The result shows as the Quick menu's notice.
    func saveReplay() {
        guard !isSavingReplay else { return }
        isSavingReplay = true
        replayTask = Task {
            let result = await onSaveReplay()
            guard !Task.isCancelled else { return }   // the stream screen was left: nothing to tell
            isSavingReplay = false
            show(PCNotice(message: result.message, succeeded: result.succeeded))
        }
    }

    static let pictureInPictureNotReady = "Picture in picture isn't ready yet. Try again in a moment."

    /// The Quick menu's Picture in picture tile. If the window can't open yet, the Quick menu says so.
    func startPictureInPicture() {
        guard !onPictureInPicture() else { return }
        show(PCNotice(message: Self.pictureInPictureNotReady, succeeded: false))
    }

    private func liveChanged() {
        readyTask?.cancel()
        guard isLive else { replayReady = false; return }
        readyTask = Task {
            try? await Task.sleep(for: replayReadyDelay)
            guard !Task.isCancelled else { return }
            replayReady = true
        }
    }

    /// The stream screen is being left: stop waiting on the Helper and on a replay save, quietly.
    func stopPCControl() {
        controlTask?.cancel()
        replayTask?.cancel()
        readyTask?.cancel()
        noticeTask?.cancel()
        runningControl = nil
        isSavingReplay = false
        replayReady = false
        pcNotice = nil
    }

    /// Gives a notice that arrived while another tab was showing its full time on screen.
    func restartNoticeTimer() {
        guard let pcNotice else { return }
        show(pcNotice, announce: false)   // already announced when it arrived
    }

    /// Every notice that comes from the model is announced to VoiceOver (and felt) here, once, when it arrives.
    private func show(_ notice: PCNotice, announce: Bool = true) {
        noticeTask?.cancel()
        if announce {
            AccessibilityNotification.Announcement(notice.message).post()
            resultFeedback = notice
        }
        withAnimation { pcNotice = notice }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { pcNotice = nil }
        }
    }

    /// The user picked a tab (tap or swipe).
    func select(_ tab: DeckTab) {
        autoSwitched = false
        guard tab != self.tab else { return }
        withAnimation(.smooth(duration: 0.25)) { self.tab = tab }
    }

    /// Puts back the tab that was showing before the sideways menu sheet opened. Unlike `select`, this
    /// isn't the user picking a tab, so an automatic Quick-menu switch still undoes itself later.
    func restore(_ tab: DeckTab) {
        guard tab != self.tab else { return }
        self.tab = tab
    }

    func swipe(forward: Bool, in tabs: [DeckTab]) {
        if let next = DeckTab.neighbor(of: tab, in: tabs, forward: forward) { select(next) }
    }

    func controllerChanged(_ hasController: Bool) {
        guard hasController != hasPhysicalController else { return }
        hasPhysicalController = hasController
        let next = DeckHandoff.afterControllerChange(current: tab, autoSwitched: autoSwitched, hasController: hasController)
        autoSwitched = next.autoSwitched
        if next.tab != tab { withAnimation(.smooth(duration: 0.25)) { tab = next.tab } }
    }
}

/// The line that slides up after a PC control finishes.
struct PCNotice: Equatable {
    let id = UUID()
    let message: String
    let succeeded: Bool

    init(_ result: PCControlResult) {
        message = result.message
        succeeded = result.succeeded
    }

    init(message: String, succeeded: Bool) {
        self.message = message
        self.succeeded = succeeded
    }
}
