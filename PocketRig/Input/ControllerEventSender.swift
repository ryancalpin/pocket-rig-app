import CMoonlight
import Foundation
import Observation

protocol ControllerEventSending: Sendable {
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16)
    /// Tells the host a controller showed up so it can pick the right virtual pad.
    func arrive(controller: Int16, activeMask: Int16, type: UInt8)
    /// The same, saying what the pad can do (`LI_CCAP_*`): rumble, trigger rumble, motion sensors.
    func arrive(controller: Int16, activeMask: Int16, type: UInt8, capabilities: UInt16)
}

extension ControllerEventSending {
    func arrive(controller: Int16, activeMask: Int16, type: UInt8) {}
    /// Senders that don't care about capabilities hear a plain arrival.
    func arrive(controller: Int16, activeMask: Int16, type: UInt8, capabilities: UInt16) {
        arrive(controller: controller, activeMask: activeMask, type: type)
    }
}

/// What a pad tells the host it can do. The host only sends rumble, trigger rumble or motion requests
/// to pads that say they support them.
enum ControllerCapabilities {
    static func flags(rumble: Bool, triggerRumble: Bool, motion: Bool) -> UInt16 {
        var flags = UInt16(LI_CCAP_ANALOG_TRIGGERS)
        if rumble { flags |= UInt16(LI_CCAP_RUMBLE) }
        if triggerRumble { flags |= UInt16(LI_CCAP_TRIGGER_RUMBLE) }
        if motion { flags |= UInt16(LI_CCAP_ACCEL) | UInt16(LI_CCAP_GYRO) }
        return flags
    }

    /// The on-screen pad: rumble and trigger rumble (felt on the phone), no motion sensors. Announcing
    /// motion could make a host switch to a PlayStation pad and change every in-game button prompt.
    static let touchPad = flags(rumble: true, triggerRumble: true, motion: false)
}

struct MoonlightControllerSender: ControllerEventSending {
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) {
        let w = state.wire
        _ = LiSendMultiControllerEvent(controller, activeMask, w.buttons, w.lt, w.rt, w.lx, w.ly, w.rx, w.ry)
    }

    func arrive(controller: Int16, activeMask: Int16, type: UInt8) {
        arrive(controller: controller, activeMask: activeMask, type: type,
               capabilities: ControllerCapabilities.flags(rumble: false, triggerRumble: false, motion: false))
    }

    func arrive(controller: Int16, activeMask: Int16, type: UInt8, capabilities: UInt16) {
        _ = LiSendControllerArrivalEvent(
            UInt8(truncatingIfNeeded: controller), UInt16(bitPattern: activeMask), type,
            UInt32(bitPattern: GamepadButtons.all.rawValue), capabilities
        )
    }
}

/// Used by previews and the debug gamepad screen.
struct NoOpControllerSender: ControllerEventSending {
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) {}
}

/// Single source of truth for the on-screen gamepad during one stream. What goes to the PC is the
/// fingers' state, plus any special buttons (turbo, tap-to-hold, combos), plus tilt aim on the right stick.
@MainActor @Observable
final class GamepadInput {
    private(set) var touchState = GamepadState()
    /// Bumped by `releaseAll()` so on-screen controls can reset their visuals.
    private(set) var resetToken = 0
    /// Tap-to-hold buttons held right now, so they can look pressed.
    private(set) var latchedIDs: Set<UUID> = []
    @ObservationIgnored private var lastSent = GamepadState().wireValues
    @ObservationIgnored private let sender: ControllerEventSending
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let timer: WakeupTimer
    @ObservationIgnored private var engine = SpecialButtonEngine()
    @ObservationIgnored private var gyroStick: SIMD2<Float> = .zero

    init(sender: ControllerEventSending,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesWakeups: Bool = true) {
        self.sender = sender
        self.now = now
        self.timer = WakeupTimer(enabled: schedulesWakeups)
    }

    /// What the PC is told right now.
    var outgoingState: GamepadState { outgoing(at: now()) }

    /// Fingers + special buttons + tilt. Triggers a special button holds are fully pulled.
    nonisolated static func merge(touch: GamepadState, special: SpecialOutput, gyro: SIMD2<Float>) -> GamepadState {
        var s = touch
        s.buttons.formUnion(special.buttons)
        if special.leftTrigger { s.leftTrigger = 1 }
        if special.rightTrigger { s.rightTrigger = 1 }
        if gyro != .zero {
            let sum = s.rightStick + gyro
            s.rightStick = [min(max(sum.x, -1), 1), min(max(sum.y, -1), 1)]
        }
        return s
    }

    /// Mutates the touch state and sends it right away, but only if something changed.
    func update(_ change: (inout GamepadState) -> Void) {
        var next = touchState
        change(&next)
        guard next != touchState else { return }
        touchState = next
        sendIfChanged(at: now())
    }

    /// A finger went down or up on a turbo, tap-to-hold or combo button.
    func special(_ id: UUID, _ binding: SpecialBinding, down: Bool) {
        let t = now()
        if down { engine.press(id, binding, at: t) } else { engine.release(id) }
        advance(at: t)
    }

    /// Moves timed special buttons along. The wake-up timer calls it; tests call it after moving the clock.
    func advanceSpecial() {
        advance(at: now())
    }

    /// Tilt aim for the right stick; `.zero` when tilt is off or still.
    func setGyroStick(_ value: SIMD2<Float>) {
        guard value != gyroStick else { return }
        gyroStick = value
        sendIfChanged(at: now())
    }

    /// Lets go of everything (gesture cancel, backgrounding, view removed). Safe to repeat.
    func releaseAll() {
        resetToken &+= 1
        engine.reset()
        timer.cancel()
        if !latchedIDs.isEmpty { latchedIDs = [] }
        gyroStick = .zero
        if touchState != GamepadState() { touchState = GamepadState() }
        sendIfChanged(at: now())
    }

    /// Call once when a live stream starts so the host creates the virtual pad.
    func announceArrival() {
        sender.arrive(controller: 0, activeMask: 1, type: UInt8(LI_CTYPE_XBOX),
                      capabilities: ControllerCapabilities.touchPad)
    }

    /// A quick press and release (Quick menu's Steam button).
    func tap(_ button: GamepadButtons) {
        update { $0.buttons.insert(button) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.update { $0.buttons.remove(button) }
        }
    }

    private func outgoing(at t: TimeInterval) -> GamepadState {
        Self.merge(touch: touchState, special: engine.output(at: t), gyro: gyroStick)
    }

    private func advance(at t: TimeInterval) {
        engine.expire(at: t)
        let latched = engine.latchedIDs
        if latched != latchedIDs { latchedIDs = latched }
        sendIfChanged(at: t)
        if let next = engine.nextChange(after: t) {
            timer.schedule(in: next - t) { [weak self] in self?.advanceSpecial() }
        } else {
            timer.cancel()
        }
    }

    /// Skips sends that differ only below the wire's resolution.
    private func sendIfChanged(at t: TimeInterval) {
        let state = outgoing(at: t)
        let wire = state.wireValues
        guard wire != lastSent else { return }
        lastSent = wire
        sender.send(state, controller: 0, activeMask: 1)
    }
}
