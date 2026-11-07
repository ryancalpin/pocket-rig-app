import Foundation
import Testing
@testable import PocketRig

func approximately(_ a: Float, _ b: Float, tolerance: Float = 0.001) -> Bool { abs(a - b) <= tolerance }
func approximately(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

/// A hand-moved clock for anything timed (trigger taps, turbo, combos).
@MainActor final class FakeClock {
    var now: TimeInterval = 100
}

@MainActor final class FakePhoneSink: PhoneHapticSink {
    private(set) var levels: [PhoneLevels] = []
    private(set) var taps: [Float] = []
    var current: PhoneLevels { levels.last ?? .zero }
    func setLevels(_ levels: PhoneLevels) { self.levels.append(levels) }
    func tap(intensity: Float) { taps.append(intensity) }
}

@MainActor final class FakeControllerSink: ControllerRumbleSink {
    var supportsTriggerRumble = false
    private(set) var motors: [PhoneLevels] = []
    private(set) var triggers: [[Float]] = []
    private(set) var stops = 0
    func setMotors(_ levels: PhoneLevels) { motors.append(levels) }
    func setTriggers(left: Float, right: Float) { triggers.append([left, right]) }
    func stop() { stops += 1 }
}

@Suite struct RumbleMixerTests {
    private func phone(_ low: UInt16, _ high: UInt16, sound: Float = 0, _ settings: FeelSnapshot,
                       takes: Bool = false, attached: Bool = false) -> PhoneLevels {
        FeelMixer.phone(low: low, high: high, sound: sound, settings: settings,
                        controllerTakesRumble: takes, controllerAttached: attached)
    }

    @Test func motorSpeedsBecomeLevels() {
        #expect(FeelMixer.motorLevel(0) == 0)
        #expect(FeelMixer.motorLevel(65535) == 1)
        #expect(approximately(FeelMixer.motorLevel(16384), 0.5))
        #expect(FeelMixer.motorLevel(10) == 0)   // noise, not rumble
    }

    @Test func heavyAndLightMotorsStaySeparate() {
        let high = FeelSnapshot(strength: .high)
        #expect(phone(65535, 0, high) == PhoneLevels(heavy: 1, light: 0))
        #expect(phone(0, 65535, high) == PhoneLevels(heavy: 0, light: 1))
        let both = phone(16384, 65535, high)
        #expect(approximately(both.heavy, 0.5))
        #expect(both.light == 1)
    }

    @Test func strengthScalesThePhone() {
        #expect(approximately(phone(65535, 0, FeelSnapshot(strength: .medium)).heavy, 0.7))
        #expect(phone(65535, 65535, FeelSnapshot(strength: .off)) == .zero)
    }

    @Test func aControllerThatCanRumbleTakesIt() {
        #expect(phone(65535, 65535, FeelSnapshot(strength: .high), takes: true, attached: true) == .zero)
        #expect(FeelMixer.controller(low: 65535, high: 0) == PhoneLevels(heavy: 1, light: 0))
    }

    @Test func soundOnlyPlaysWhenItIsOnAndNothingElseIs() {
        let on = FeelSnapshot(strength: .medium, feelTheSound: true)
        #expect(approximately(phone(0, 0, sound: 0.5, on).heavy, 0.28))
        #expect(phone(0, 0, sound: 0.5, on).light == 0)
        #expect(phone(65535, 0, sound: 0.5, on) == PhoneLevels(heavy: 0.7, light: 0))   // rumble wins
        #expect(phone(0, 0, sound: 0.5, on, attached: true) == .zero)                   // controller in hand
        #expect(phone(0, 0, sound: 0.5, FeelSnapshot(strength: .medium)) == .zero)      // switched off
        #expect(phone(0, 0, sound: 0.01, on) == .zero)                                   // too quiet to bother
    }
}

@Suite struct TriggerTapSchedulerTests {
    @Test func theFirstTapIsImmediate() {
        var s = TriggerTapScheduler()
        #expect(s.update(left: 65535, right: 0, at: 0) == 1)
        #expect(s.tick(at: 0.01) == nil)
        #expect(approximately(s.nextTapTime ?? -1, 0.05))
        #expect(s.tick(at: 0.051) == 1)
        #expect(approximately(s.nextTapTime ?? -1, 0.101))
    }

    @Test func weakerRumbleTapsMoreSlowly() {
        #expect(approximately(TriggerTapScheduler.interval(for: 1), 0.05))
        #expect(approximately(TriggerTapScheduler.interval(for: 0.5), 0.10))
        #expect(approximately(TriggerTapScheduler.interval(for: 0), 0.15))
    }

    @Test func eitherTriggerCounts() {
        var s = TriggerTapScheduler()
        #expect(approximately(s.update(left: 0, right: 16384, at: 0) ?? 0, 0.5))
    }

    @Test func aChangeMidRumbleKeepsTheRhythm() {
        var s = TriggerTapScheduler()
        _ = s.update(left: 65535, right: 0, at: 0)
        #expect(s.update(left: 16384, right: 0, at: 0.02) == nil)
        #expect(approximately(s.nextTapTime ?? -1, 0.05))
    }

    @Test func stoppingEndsTheTaps() {
        var s = TriggerTapScheduler()
        _ = s.update(left: 65535, right: 0, at: 0)
        #expect(s.update(left: 0, right: 0, at: 0.02) == nil)
        #expect(s.nextTapTime == nil)
        #expect(s.tick(at: 1) == nil)
    }
}

@Suite @MainActor struct FeelControllerTests {
    private func make(_ settings: FeelSnapshot = FeelSnapshot()) -> (FeelController, FakePhoneSink, FakeClock) {
        let phone = FakePhoneSink(), clock = FakeClock()
        let feel = FeelController(phone: phone, settings: settings, now: { clock.now }, schedulesWakeups: false)
        return (feel, phone, clock)
    }

    @Test func rumbleReachesThePhone() {
        let (feel, phone, _) = make()
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        #expect(approximately(phone.current.heavy, 0.7))
        #expect(phone.current.light == 0)
    }

    @Test func onlyRealChangesReachTheMotor() {
        let (feel, phone, _) = make()
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        feel.handle(.rumble(controller: 0, low: 65535, high: 65535))
        #expect(phone.levels.count == 2)
    }

    @Test func zeroAndZeroStopsTheMotor() {
        let (feel, phone, _) = make()
        feel.handle(.rumble(controller: 0, low: 65535, high: 65535))
        feel.handle(.rumble(controller: 0, low: 0, high: 0))
        #expect(phone.current == .zero)
    }

    @Test func otherControllerSlotsAreIgnored() {
        let (feel, phone, _) = make()
        feel.handle(.rumble(controller: 1, low: 65535, high: 65535))
        feel.handle(.triggerRumble(controller: 2, left: 65535, right: 0))
        #expect(phone.levels.isEmpty)
        #expect(phone.taps.isEmpty)
    }

    @Test func aStrengthChangeAppliesAtOnce() {
        let (feel, phone, _) = make()
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        feel.apply(FeelSnapshot(strength: .high))
        #expect(phone.current.heavy == 1)
        feel.apply(FeelSnapshot(strength: .off))
        #expect(phone.current == .zero)
    }

    @Test func aControllerTakesTheRumbleAtFullStrength() {
        let (feel, phone, _) = make()
        let pad = FakeControllerSink()
        feel.controllerChanged(attached: true, rumble: pad)
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        #expect(pad.motors.last == PhoneLevels(heavy: 1, light: 0))
        #expect(phone.current == .zero)
    }

    @Test func aControllerThatCantRumbleLeavesItOnThePhone() {
        let (feel, phone, _) = make()
        feel.controllerChanged(attached: true, rumble: nil)
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        #expect(approximately(phone.current.heavy, 0.7))
    }

    @Test func swappingControllersStopsTheOldOne() {
        let (feel, _, _) = make()
        let first = FakeControllerSink(), second = FakeControllerSink()
        feel.controllerChanged(attached: true, rumble: first)
        feel.handle(.rumble(controller: 0, low: 0, high: 65535))
        feel.controllerChanged(attached: true, rumble: second)
        #expect(first.stops == 1)
        #expect(second.motors.last == PhoneLevels(heavy: 0, light: 1))   // picks up the rumble in progress
    }

    @Test func stopAllSilencesEverything() {
        let (feel, phone, _) = make()
        let pad = FakeControllerSink()
        feel.handle(.rumble(controller: 0, low: 65535, high: 65535))
        feel.stopAll()
        #expect(phone.current == .zero)
        feel.controllerChanged(attached: true, rumble: pad)
        feel.handle(.rumble(controller: 0, low: 65535, high: 0))
        feel.stopAll()
        #expect(pad.motors.last == .zero)
    }

    @Test func soundFillsInWhenTheGameIsNotRumbling() {
        let (feel, phone, _) = make(FeelSnapshot(strength: .medium, feelTheSound: true))
        feel.handle(.soundLevel(0.5))
        #expect(approximately(phone.current.heavy, 0.28))
        feel.handle(.rumble(controller: 0, low: 0, high: 65535))
        #expect(phone.current == PhoneLevels(heavy: 0, light: 0.7))
        feel.handle(.rumble(controller: 0, low: 0, high: 0))
        #expect(approximately(phone.current.heavy, 0.28))
    }

    @Test func soundFadesWhenNoNewLevelArrives() {
        let (feel, phone, clock) = make(FeelSnapshot(strength: .medium, feelTheSound: true))
        feel.handle(.soundLevel(0.5))
        #expect(phone.current.heavy > 0)
        clock.now += 0.1
        feel.tickSound()   // too soon: still playing
        #expect(phone.current.heavy > 0)
        clock.now += 0.06
        feel.tickSound()
        #expect(phone.current == .zero)
    }

    @Test func aFreshLevelKeepsTheSoundGoing() {
        let (feel, phone, clock) = make(FeelSnapshot(strength: .medium, feelTheSound: true))
        feel.handle(.soundLevel(0.5))
        clock.now += 0.1
        feel.handle(.soundLevel(0.6))
        clock.now += 0.1
        feel.tickSound()   // 0.1 s since the last level
        #expect(phone.current.heavy > 0)
    }

    @Test func soundTimeoutDoesNothingWhenSoundIsOff() {
        let (feel, phone, clock) = make()
        feel.handle(.soundLevel(1))
        clock.now += 1
        feel.tickSound()
        #expect(phone.levels.isEmpty)
    }

    @Test func soundIsIgnoredWhenSwitchedOff() {
        let (feel, phone, _) = make()
        feel.handle(.soundLevel(1))
        #expect(phone.levels.isEmpty)
    }

    @Test func triggerRumbleTapsThePhone() {
        let (feel, phone, clock) = make()
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 0))
        #expect(phone.taps.count == 1)
        #expect(approximately(phone.taps[0], 0.7))
        clock.now += 0.02
        feel.tickTriggers()
        #expect(phone.taps.count == 1)
        clock.now += 0.04
        feel.tickTriggers()
        #expect(phone.taps.count == 2)
        feel.handle(.triggerRumble(controller: 0, left: 0, right: 0))
        clock.now += 1
        feel.tickTriggers()
        #expect(phone.taps.count == 2)
    }

    @Test func aControllerWithTriggerMotorsGetsTriggerRumble() {
        let (feel, phone, _) = make()
        let pad = FakeControllerSink()
        pad.supportsTriggerRumble = true
        feel.controllerChanged(attached: true, rumble: pad)
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 0))
        #expect(pad.triggers.last == [1, 0])
        #expect(phone.taps.isEmpty)
    }

    @Test func aControllerWithoutTriggerMotorsMeansNoTaps() {
        let (feel, phone, _) = make()
        let pad = FakeControllerSink()
        feel.controllerChanged(attached: true, rumble: pad)
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 0))
        #expect(pad.triggers.isEmpty)
        #expect(phone.taps.isEmpty)
    }

    @Test func offMeansNoTriggerTaps() {
        let (feel, phone, _) = make(FeelSnapshot(strength: .off))
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 65535))
        #expect(phone.taps.isEmpty)
    }

    @Test func offMeansNoTriggerWakeups() {
        let (feel, phone, clock) = make(FeelSnapshot(strength: .off))
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 65535))
        #expect(!feel.triggerTapsActive)   // nothing scheduled while off
        clock.now += 1
        feel.tickTriggers()
        #expect(!feel.triggerTapsActive)
        #expect(phone.taps.isEmpty)
    }

    @Test func turningOffEndsActiveTriggerTaps() {
        let (feel, phone, clock) = make()
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 0))
        #expect(feel.triggerTapsActive)
        feel.apply(FeelSnapshot(strength: .off))
        #expect(!feel.triggerTapsActive)
        clock.now += 1
        feel.tickTriggers()
        #expect(phone.taps.count == 1)   // only the first tap, before it was turned off
    }

    @Test func stopAllEndsActiveTriggerTaps() {
        let (feel, phone, clock) = make()
        feel.handle(.triggerRumble(controller: 0, left: 65535, right: 0))
        feel.stopAll()
        #expect(!feel.triggerTapsActive)
        clock.now += 1
        feel.tickTriggers()
        #expect(phone.taps.count == 1)
    }

    @Test func phoneHapticsIsSafeWithoutAMotor() {
        // Only runs where there is no Core Haptics hardware (the simulator), so it can never vibrate
        // a real phone. Every call must quietly do nothing.
        #if targetEnvironment(simulator)
        let haptics = PhoneHaptics()
        haptics.setLevels(PhoneLevels(heavy: 1, light: 1))
        haptics.tap(intensity: 1)
        haptics.setLevels(.zero)
        haptics.shutdown()
        #expect(!PhoneHaptics.isSupported)
        #endif
    }
}
