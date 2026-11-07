import Foundation
import Observation

/// Turns presses on the practice pad into a combo, keeping their timing. Waiting before the first
/// press and after the last release isn't part of the combo.
struct MacroRecorder: Sendable {
    private(set) var steps: [MacroStep] = []
    private var current: MacroFrame?
    private var since: TimeInterval = 0

    var hasPresses: Bool { steps.contains { !$0.frame.isEmpty } || !(current?.isEmpty ?? true) }

    /// No room for more: one step is kept free for the press still in progress.
    var isFull: Bool {
        steps.count >= Macro.maximumSteps - 1 || steps.reduce(0) { $0 + $1.seconds } >= Macro.longestCombo
    }

    var pressCount: Int {
        var all = steps
        if let current { all.append(MacroStep(frame: current, seconds: Macro.shortestStep)) }
        return Macro(steps: all).pressCount
    }

    /// The pad changed to `frame`.
    mutating func record(_ frame: MacroFrame, at now: TimeInterval) {
        guard let current else {
            guard !frame.isEmpty, !isFull else { return }
            self.current = frame
            since = now
            return
        }
        guard frame != current else { return }
        // At the limit the press still held is closed by its release, but nothing new is opened.
        let wasFull = isFull
        closeStep(at: now)
        guard !wasFull else { return }
        self.current = frame
        since = now
    }

    /// The combo so far, ending now.
    func finished(at now: TimeInterval) -> Macro {
        var copy = self
        copy.closeStep(at: now)
        while copy.steps.last?.frame.isEmpty == true { copy.steps.removeLast() }
        return Macro(steps: copy.steps).sanitized()
    }

    mutating func reset() {
        self = MacroRecorder()
    }

    private mutating func closeStep(at now: TimeInterval) {
        guard let current else { return }
        let seconds = min(max(now - since, Macro.shortestStep), Macro.longestStep)
        steps.append(MacroStep(frame: current, seconds: seconds))
        self.current = nil
    }

    /// The practice pad: one of each button, trigger and the d-pad from the layout, all plain. Sticks
    /// aren't recorded, so they're left off.
    static func recordingPad(from buttons: [ControlButton]) -> [ControlButton] {
        var seen = Set<ControlKind>()
        return buttons.compactMap { button in
            guard !button.isHidden, button.kind != .leftStick, button.kind != .rightStick,
                  seen.insert(button.kind).inserted else { return nil }
            var plain = button
            plain.behavior = .normal
            plain.macro = nil
            return plain
        }
    }
}

/// Feeds the practice pad's presses into a recorder.
struct MacroRecordingSender: ControllerEventSending {
    weak var session: MacroRecordingSession?

    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) {
        let session = self.session
        // `GamepadInput` sends from the main actor.
        MainActor.assumeIsolated { session?.record(state) }
    }
}

/// One "Record a combo" sheet: its practice pad and what has been recorded.
@MainActor @Observable
final class MacroRecordingSession {
    private(set) var recorder = MacroRecorder()
    @ObservationIgnored private(set) var input: GamepadInput!
    @ObservationIgnored private let now: @MainActor () -> TimeInterval

    init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        input = GamepadInput(sender: MacroRecordingSender(session: self), now: now, schedulesWakeups: false)
    }

    func record(_ state: GamepadState) {
        recorder.record(MacroFrame(state), at: now())
    }

    func startOver() {
        input.releaseAll()
        recorder.reset()
    }

    func finished() -> Macro {
        recorder.finished(at: now())
    }
}
