import Foundation

/// Where phone vibration goes. Tests use a fake that records what would have played.
@MainActor
protocol PhoneHapticSink: AnyObject {
    func setLevels(_ levels: PhoneLevels)
    func tap(intensity: Float)
}

/// A connected controller's rumble motors.
@MainActor
protocol ControllerRumbleSink: AnyObject {
    var supportsTriggerRumble: Bool { get }
    func setMotors(_ levels: PhoneLevels)
    func setTriggers(left: Float, right: Float)
    func stop()
}

/// Routes everything the stream wants felt. Rumble goes to the controller when one can take it,
/// otherwise to the phone. Trigger rumble becomes phone taps unless the controller has trigger motors.
/// Feel-the-sound fills in when nothing else is vibrating. One per stream screen.
@MainActor
final class FeelController {
    private let phone: any PhoneHapticSink
    private let now: @MainActor () -> TimeInterval
    private let timer: WakeupTimer
    private let soundTimer: WakeupTimer
    /// How long a sound level holds with no newer one before it fades to nothing.
    static let soundTimeout: TimeInterval = 0.15
    private var lastSoundTime: TimeInterval = 0
    private(set) var settings: FeelSnapshot
    private var controller: (any ControllerRumbleSink)?
    private(set) var controllerAttached = false
    private var low: UInt16 = 0
    private var high: UInt16 = 0
    private var sound: Float = 0
    private var triggerTaps = TriggerTapScheduler()
    /// What the phone is playing now.
    private(set) var phoneLevels = PhoneLevels.zero

    init(phone: any PhoneHapticSink, settings: FeelSnapshot = FeelSnapshot(),
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedulesWakeups: Bool = true) {
        self.phone = phone
        self.settings = settings
        self.now = now
        self.timer = WakeupTimer(enabled: schedulesWakeups)
        self.soundTimer = WakeupTimer(enabled: schedulesWakeups)
    }

    func apply(_ settings: FeelSnapshot) {
        self.settings = settings
        if !settings.listensToSound { endSound() }
        if !tapsAreOn { endTriggerTaps() }
        refresh()
    }

    /// True while trigger taps are waiting to play (tests read it; the wake-up timer follows it).
    var triggerTapsActive: Bool { triggerTaps.nextTapTime != nil }

    private var tapsAreOn: Bool { settings.strength.scale > 0 }

    private func endSound() {
        sound = 0
        soundTimer.cancel()
    }

    private func endTriggerTaps() {
        triggerTaps.reset()
        timer.cancel()
    }

    /// A controller connected or left. `rumble` is nil when there is none, or it can't rumble.
    func controllerChanged(attached: Bool, rumble: (any ControllerRumbleSink)?) {
        controller?.stop()
        controller = rumble
        controllerAttached = attached
        triggerTaps.reset()
        timer.cancel()
        controller?.setMotors(FeelMixer.controller(low: low, high: high))
        refresh()
    }

    func handle(_ feedback: HostFeedback) {
        switch feedback {
        case .rumble(let number, let low, let high):
            guard number == 0 else { return }   // one pad, in slot 0
            self.low = low
            self.high = high
            controller?.setMotors(FeelMixer.controller(low: low, high: high))
            refresh()
        case .triggerRumble(let number, let left, let right):
            guard number == 0 else { return }
            triggers(left: left, right: right)
        case .soundLevel(let level):
            sound = settings.listensToSound ? level : 0
            lastSoundTime = now()
            scheduleSoundTimeout()
            refresh()
        case .motionRequest:
            break   // motion readings are the motion code's job, not vibration
        }
    }

    /// Plays a trigger tap if one is due. The wake-up timer calls it; tests call it after moving the clock.
    func tickTriggers() {
        guard tapsAreOn else {
            endTriggerTaps()
            return
        }
        if let level = triggerTaps.tick(at: now()) { tap(level) }
        scheduleTriggerTick()
    }

    /// Fades the sound to nothing once no level has arrived for `soundTimeout` (a stalled network, or a PC
    /// that sends nothing in silence). The wake-up timer calls it; tests call it after moving the clock.
    func tickSound() {
        guard sound > 0 else { return }
        if now() - lastSoundTime >= Self.soundTimeout - 0.0001 {
            sound = 0
            refresh()
        } else {
            scheduleSoundTimeout()
        }
    }

    private func scheduleSoundTimeout() {
        guard sound > 0 else {
            soundTimer.cancel()
            return
        }
        let wait = lastSoundTime + Self.soundTimeout - now()
        soundTimer.schedule(in: wait) { [weak self] in self?.tickSound() }
    }

    /// The stream stopped or is reconnecting: nothing may keep vibrating.
    func stopAll() {
        low = 0
        high = 0
        endSound()
        triggerTaps.reset()
        timer.cancel()
        controller?.setMotors(.zero)
        controller?.setTriggers(left: 0, right: 0)
        refresh()
    }

    private func triggers(left: UInt16, right: UInt16) {
        if let controller, controller.supportsTriggerRumble {
            controller.setTriggers(left: FeelMixer.motorLevel(left), right: FeelMixer.motorLevel(right))
            return
        }
        // With a controller in hand, taps on the phone's on-screen triggers wouldn't be felt.
        guard !controllerAttached else { return }
        guard tapsAreOn else {   // strength off: no taps, so no wake-ups either
            endTriggerTaps()
            return
        }
        if let level = triggerTaps.update(left: left, right: right, at: now()) { tap(level) }
        scheduleTriggerTick()
    }

    private func tap(_ level: Float) {
        let intensity = level * settings.strength.scale
        if intensity > 0 { phone.tap(intensity: intensity) }
    }

    private func scheduleTriggerTick() {
        guard let next = triggerTaps.nextTapTime else {
            timer.cancel()
            return
        }
        timer.schedule(in: next - now()) { [weak self] in self?.tickTriggers() }
    }

    private func refresh() {
        let levels = FeelMixer.phone(low: low, high: high, sound: sound, settings: settings,
                                     controllerTakesRumble: controller != nil,
                                     controllerAttached: controllerAttached)
        guard levels != phoneLevels else { return }
        phoneLevels = levels
        phone.setLevels(levels)
    }
}
