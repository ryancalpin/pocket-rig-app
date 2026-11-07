import CMoonlight
import Foundation
import GameController
import Observation

/// Slot 0's physical pad state plus buttons the app holds down on top of it (the Quick menu's Steam
/// button). Touch and physical pads share slot 0, so a tap must be OR'd into what the pad is doing
/// rather than sent as its own state, or a stick or trigger the player holds would read as released.
/// Lock-protected: the pad's change handler and the main actor both use it.
final class PhysicalPadMerger: @unchecked Sendable {
    private let lock = NSLock()
    private var physical = GamepadState()
    private var extra: GamepadButtons = []
    private var gyro: SIMD2<Float> = .zero

    private func merged() -> GamepadState {
        GamepadInput.merge(touch: physical, special: SpecialOutput(buttons: extra), gyro: gyro)
    }

    /// The pad moved; returns the state to send.
    func physicalChanged(_ state: GamepadState) -> GamepadState {
        lock.withLock { physical = state; return merged() }
    }

    func hold(_ buttons: GamepadButtons) -> GamepadState {
        lock.withLock { extra.formUnion(buttons); return merged() }
    }

    func release(_ buttons: GamepadButtons) -> GamepadState {
        lock.withLock { extra.subtract(buttons); return merged() }
    }

    /// Tilt aim on the pad's right stick.
    func setGyro(_ value: SIMD2<Float>) -> GamepadState {
        lock.withLock { gyro = value; return merged() }
    }

    func reset() {
        lock.withLock { physical = GamepadState(); extra = []; gyro = .zero }
    }
}

@MainActor @Observable
final class PhysicalControllerMonitor {
    private(set) var hasController = false
    /// Changes whenever the connected pad changes, even from one pad straight to another.
    private(set) var currentID: ObjectIdentifier?

    /// The pad in use, for rumble and motion. Nil when none (or the monitor isn't running).
    var current: GCController? { active }

    @ObservationIgnored private let sender: ControllerEventSending
    @ObservationIgnored private var active: GCController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let merger = PhysicalPadMerger()
    @ObservationIgnored private var lastGyro: SIMD2<Float> = .zero

    init(sender: ControllerEventSending) {
        self.sender = sender
    }

    /// Whether a physical pad is connected right now (before streaming, when the monitor isn't running).
    static func isPadConnected() -> Bool {
        guard !DebugLaunchOptions.ignorePhysicalControllers else { return false }
        return GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    func start() {
        guard observers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        detach()
    }

    private func refresh() {
        if let current = active, GCController.controllers().contains(current) { return }
        detach()
        guard !DebugLaunchOptions.ignorePhysicalControllers, let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad else { return }
        active = controller
        currentID = ObjectIdentifier(controller)
        hasController = true
        sender.arrive(controller: 0, activeMask: 1, type: Self.controllerType(controller),
                      capabilities: Self.capabilities(for: controller))
        let sender = self.sender, merger = self.merger
        merger.reset()
        _ = merger.physicalChanged(Self.state(from: pad))
        pad.valueChangedHandler = { gamepad, _ in
            sender.send(merger.physicalChanged(Self.state(from: gamepad)), controller: 0, activeMask: 1)
        }
    }

    /// A quick press and release on top of whatever the physical pad is doing (Quick menu's Steam button).
    func tap(_ button: GamepadButtons) {
        guard let controller = active else { return }
        sender.send(merger.hold(button), controller: 0, activeMask: 1)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.active === controller else { return }
            self.sender.send(self.merger.release(button), controller: 0, activeMask: 1)
        }
    }

    /// Tilt aim while a pad is in use: added to its right stick.
    func setGyroStick(_ value: SIMD2<Float>) {
        guard active != nil, value != lastGyro else { return }
        lastGyro = value
        sender.send(merger.setGyro(value), controller: 0, activeMask: 1)
    }

    private func detach() {
        active?.extendedGamepad?.valueChangedHandler = nil
        if active != nil {
            // Tell the host the pad is gone: empty event with our mask bit cleared.
            sender.send(GamepadState(), controller: 0, activeMask: 0)
        }
        active = nil
        currentID = nil
        hasController = false
        merger.reset()
        lastGyro = .zero
    }

    private static func controllerType(_ controller: GCController) -> UInt8 {
        let category = controller.productCategory
        if category.contains("DualShock") || category.contains("DualSense") { return UInt8(LI_CTYPE_PS) }
        if category.contains("Xbox") { return UInt8(LI_CTYPE_XBOX) }
        return UInt8(LI_CTYPE_UNKNOWN)
    }

    /// What this pad can do, so the host sends it rumble, trigger rumble and motion requests.
    static func capabilities(for controller: GCController) -> UInt16 {
        let localities = controller.haptics?.supportedLocalities ?? []
        let triggerMotors = localities.contains(.triggers) || localities.contains(.leftTrigger)
            || localities.contains(.rightTrigger)
        return ControllerCapabilities.flags(rumble: controller.haptics != nil, triggerRumble: triggerMotors,
                                            motion: controller.motion?.hasRotationRate == true)
    }

    static func state(from gamepad: GCExtendedGamepad) -> GamepadState {
        var s = GamepadState()
        let map: [(GCControllerButtonInput?, GamepadButtons)] = [
            (gamepad.buttonA, .a), (gamepad.buttonB, .b), (gamepad.buttonX, .x), (gamepad.buttonY, .y),
            (gamepad.dpad.up, .up), (gamepad.dpad.down, .down),
            (gamepad.dpad.left, .left), (gamepad.dpad.right, .right),
            (gamepad.leftShoulder, .leftBumper), (gamepad.rightShoulder, .rightBumper),
            (gamepad.leftThumbstickButton, .leftStick), (gamepad.rightThumbstickButton, .rightStick),
            (gamepad.buttonMenu, .start), (gamepad.buttonOptions, .back), (gamepad.buttonHome, .guide),
        ]
        for (button, flag) in map where button?.isPressed == true {
            s.buttons.insert(flag)
        }
        s.leftTrigger = gamepad.leftTrigger.value
        s.rightTrigger = gamepad.rightTrigger.value
        s.leftStick = [gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value]
        s.rightStick = [gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value]
        return s
    }
}
