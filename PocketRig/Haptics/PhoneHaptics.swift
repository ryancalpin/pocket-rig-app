import AVFAudio
import CoreHaptics
import UIKit
import os

private let hapticsLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "haptics")

/// One endless vibration on a haptic engine whose strength changes on the fly. The player keeps
/// running and only its intensity moves, so rumble updates never restart the motor.
@MainActor
final class ContinuousHapticChannel {
    /// A continuous event can last at most 30 s; the player loops it.
    private static let eventSeconds: TimeInterval = 30

    private let engine: CHHapticEngine
    private let sharpness: Float
    private var player: CHHapticAdvancedPatternPlayer?
    private var isPlaying = false
    /// What the game last asked for. Kept even when the engine loses the player, so it can be replayed.
    private(set) var intensity: Float = 0

    init(engine: CHHapticEngine, sharpness: Float) {
        self.engine = engine
        self.sharpness = sharpness
    }

    /// 0 stops the motor; anything else plays at that strength (0…1).
    func set(_ value: Float) {
        let value = min(max(value.isFinite ? value : 0, 0), 1)
        guard value != intensity || (value > 0 && !isPlaying) else { return }
        intensity = value
        if value == 0 {
            discardPlayer()
            return
        }
        do {
            if let player, isPlaying {
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                     value: value, relativeTime: 0)],
                                          atTime: CHHapticTimeImmediate)
            } else {
                // Start and set the strength back to back, so the player is at the target from its first
                // moment. (A strength baked into the pattern would snap back every time the 30 s loop restarts.)
                discardPlayer()
                let player = try makePlayer()
                self.player = player
                try player.start(atTime: CHHapticTimeImmediate)
                isPlaying = true
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                     value: value, relativeTime: 0)],
                                          atTime: CHHapticTimeImmediate)
            }
        } catch {
            hapticsLog.error("Haptic channel failed: \(error.localizedDescription, privacy: .public)")
            // The next call (including a replay) sees no player and builds a new one.
            discardPlayer()
        }
    }

    /// The engine stopped or was reset: whatever player we had is gone. Remembers the strength.
    func engineLost() {
        discardPlayer()
    }

    /// Plays the remembered strength again on a fresh player (only if something was held).
    func replay() {
        let value = intensity
        guard value > 0 else { return }
        intensity = 0
        set(value)
    }

    /// Always stops a player before dropping it, so a dropped loop can't keep vibrating.
    private func discardPlayer() {
        if let player {
            do { try player.stop(atTime: CHHapticTimeImmediate) } catch {
                hapticsLog.error("Haptic player didn't stop: \(error.localizedDescription, privacy: .public)")
            }
        }
        player = nil
        isPlaying = false
    }

    private func makePlayer() throws -> CHHapticAdvancedPatternPlayer {
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0, duration: Self.eventSeconds)
        let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
        player.loopEnabled = true
        player.loopEnd = Self.eventSeconds
        return player
    }
}

/// The phone's own vibration motor, through Core Haptics. Does nothing on phones (and simulators)
/// without Core Haptics. Every decision about *what* to play lives in `FeelMixer` / `FeelController`.
@MainActor
final class PhoneHaptics: PhoneHapticSink {
    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private var engine: CHHapticEngine?
    private var heavy: ContinuousHapticChannel?
    private var light: ContinuousHapticChannel?
    private var isRunning = false
    private var triedEngine = false
    /// Bumped whenever the engine starts. Engine callbacks read it when they fire, then hop to the main
    /// actor late; one tagged with an older number fired before the latest start and is stale.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Cheap: SwiftUI may create several of these while building a view. The engine is made on first use.
    init() {}

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setLevels(_ levels: PhoneLevels) {
        guard levels.isZero || startIfNeeded() else { return }
        heavy?.set(levels.heavy)
        light?.set(levels.light)
    }

    func tap(intensity: Float) {
        guard intensity > 0, startIfNeeded(), let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(intensity, 1)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1),
        ], relativeTime: 0)
        do {
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
                .start(atTime: CHHapticTimeImmediate)
        } catch {
            hapticsLog.error("Haptic tap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The stream is over: stop the motor and let the engine sleep.
    func shutdown() {
        heavy?.set(0)
        light?.set(0)
        isRunning = false   // the stop below is ours: engineLost ignores callbacks while not running
        engine?.stop()
        heavy?.engineLost()
        light?.engineLost()
    }

    private func makeEngineIfNeeded() -> CHHapticEngine? {
        if let engine { return engine }
        guard !triedEngine else { return nil }
        triedEngine = true
        guard Self.isSupported, let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        let generation = self.generation
        engine.resetHandler = { [weak self] in
            let tag = generation.withLock { $0 }
            Task { @MainActor in self?.engineLost(tag: tag) }
        }
        engine.stoppedHandler = { [weak self] _ in
            let tag = generation.withLock { $0 }
            Task { @MainActor in self?.engineLost(tag: tag) }
        }
        self.engine = engine
        heavy = ContinuousHapticChannel(engine: engine, sharpness: 0.05)   // deep and soft
        light = ContinuousHapticChannel(engine: engine, sharpness: 0.9)    // sharp and crisp
        observeReturns()
        return engine
    }

    private func startIfNeeded() -> Bool {
        guard let engine = makeEngineIfNeeded() else { return false }
        if isRunning { return true }
        do {
            try engine.start()
            generation.withLock { $0 += 1 }
            isRunning = true
        } catch {
            hapticsLog.error("Haptic engine didn't start: \(error.localizedDescription, privacy: .public)")
        }
        return isRunning
    }

    /// The engine stopped or was reset. Players are gone; bring back anything the game is still holding.
    private func engineLost(tag: Int) {
        // Stale (fired before the latest start) or our own shutdown: nothing to recover.
        guard isRunning, tag == generation.withLock({ $0 }) else { return }
        isRunning = false
        heavy?.engineLost()
        light?.engineLost()
        resumeHeldRumble()
    }

    /// Restarts the engine and replays held rumble, only while the app is on screen. In the background
    /// (or mid-interruption) it waits; the return to the foreground or the interruption's end tries again.
    private func resumeHeldRumble() {
        guard (heavy?.intensity ?? 0) > 0 || (light?.intensity ?? 0) > 0 else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard startIfNeeded() else { return }
        heavy?.replay()
        light?.replay()
    }

    private func observeReturns() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returned() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended else { return }
            MainActor.assumeIsolated { self?.returned() }
        })
    }

    private func returned() {
        guard !isRunning else { return }
        resumeHeldRumble()
    }
}
