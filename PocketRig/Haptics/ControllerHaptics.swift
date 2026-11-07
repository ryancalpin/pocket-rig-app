import CoreHaptics
import GameController
import UIKit
import os

private let hapticsLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "haptics")

/// Which of a controller's motors plays what. Xbox and PlayStation pads have a big motor in the left grip
/// and a small one in the right; some pads have one motor; some also have motors in the triggers.
struct ControllerHapticsPlan: Equatable {
    var heavy: GCHapticsLocality
    var light: GCHapticsLocality?
    var leftTrigger: GCHapticsLocality?
    var rightTrigger: GCHapticsLocality?

    var hasTriggerMotors: Bool { leftTrigger != nil || rightTrigger != nil }

    static func make(localities: Set<GCHapticsLocality>) -> ControllerHapticsPlan {
        var plan: ControllerHapticsPlan
        if localities.contains(.leftHandle), localities.contains(.rightHandle) {
            plan = ControllerHapticsPlan(heavy: .leftHandle, light: .rightHandle)
        } else if localities.contains(.handles) {
            plan = ControllerHapticsPlan(heavy: .handles)
        } else {
            plan = ControllerHapticsPlan(heavy: .default)
        }
        if localities.contains(.leftTrigger), localities.contains(.rightTrigger) {
            plan.leftTrigger = .leftTrigger
            plan.rightTrigger = .rightTrigger
        } else if localities.contains(.triggers) {
            plan.leftTrigger = .triggers   // one engine drives both triggers
        }
        return plan
    }
}

/// One motor (or motor group) on a controller: its own haptic engine plus a continuous channel.
/// If the engine stops or resets while the game is still holding rumble, it restarts and plays it again.
@MainActor
private final class ControllerMotor {
    private let engine: CHHapticEngine
    private let channel: ContinuousHapticChannel
    private var running = false
    /// Bumped on every start. Engine callbacks read it when they fire, then hop to the main actor late;
    /// one tagged with an older number fired before the latest start and is stale.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality, sharpness: Float) {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        self.engine = engine
        self.channel = ContinuousHapticChannel(engine: engine, sharpness: sharpness)
        let generation = self.generation
        engine.resetHandler = { [weak self] in
            let tag = generation.withLock { $0 }
            Task { @MainActor in self?.engineLost(tag: tag) }
        }
        engine.stoppedHandler = { [weak self] _ in
            let tag = generation.withLock { $0 }
            Task { @MainActor in self?.engineLost(tag: tag) }
        }
    }

    func set(_ value: Float) {
        if value > 0, !start() { return }
        channel.set(value)
    }

    func stop() {
        channel.set(0)
        running = false   // the stop below is ours: engineLost ignores callbacks while not running
        engine.stop()
        channel.engineLost()
    }

    private func start() -> Bool {
        if running { return true }
        do {
            try engine.start()
            generation.withLock { $0 += 1 }
            running = true
        } catch {
            hapticsLog.error("Controller haptic engine didn't start: \(error.localizedDescription, privacy: .public)")
        }
        return running
    }

    private func engineLost(tag: Int) {
        guard running, tag == generation.withLock({ $0 }) else { return }   // stale, or our own stop
        running = false
        channel.engineLost()
        guard channel.intensity > 0, UIApplication.shared.applicationState == .active, start() else { return }
        channel.replay()
    }
}

/// A connected controller's rumble, through GameController haptics. Plays the game's motor values as
/// sent (the phone's strength setting is for the phone). Nil for pads with no motors.
@MainActor
final class ControllerHaptics: ControllerRumbleSink {
    let plan: ControllerHapticsPlan
    private let heavy: ControllerMotor
    private let light: ControllerMotor?
    private let leftTrigger: ControllerMotor?
    private let rightTrigger: ControllerMotor?

    init?(controller: GCController) {
        guard let haptics = controller.haptics else { return nil }
        let plan = ControllerHapticsPlan.make(localities: haptics.supportedLocalities)
        guard let heavy = ControllerMotor(haptics: haptics, locality: plan.heavy, sharpness: 0.1) else { return nil }
        self.plan = plan
        self.heavy = heavy
        light = plan.light.flatMap { ControllerMotor(haptics: haptics, locality: $0, sharpness: 0.8) }
        leftTrigger = plan.leftTrigger.flatMap { ControllerMotor(haptics: haptics, locality: $0, sharpness: 1) }
        rightTrigger = plan.rightTrigger.flatMap { ControllerMotor(haptics: haptics, locality: $0, sharpness: 1) }
    }

    var supportsTriggerRumble: Bool { leftTrigger != nil }

    func setMotors(_ levels: PhoneLevels) {
        if let light {
            heavy.set(levels.heavy)
            light.set(levels.light)
        } else {
            heavy.set(max(levels.heavy, levels.light))   // one motor: the stronger of the two
        }
    }

    func setTriggers(left: Float, right: Float) {
        if let rightTrigger {
            leftTrigger?.set(left)
            rightTrigger.set(right)
        } else {
            leftTrigger?.set(max(left, right))
        }
    }

    func stop() {
        heavy.stop()
        light?.stop()
        leftTrigger?.stop()
        rightTrigger?.stop()
    }
}
