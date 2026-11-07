import Foundation

/// What pressing an on-screen button does.
enum ButtonBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    case normal, turbo, toggle, macro

    static let defaultTurboHz = 15
    static let turboRange = 2...30
    static let turboChoices = [5, 10, 15, 20]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .turbo: "Turbo"
        case .toggle: "Tap to hold"
        case .macro: "Combo"
        }
    }

    var explanation: String {
        switch self {
        case .normal: "Pressed while your finger is on it."
        case .turbo: "Presses over and over while you hold it."
        case .toggle: "Tap once to hold it down. Tap again to let go."
        case .macro: "Plays a combo you record, with its timing."
        }
    }

    /// The small mark shown on the button, so you can tell it apart.
    var badgeSymbol: String? {
        switch self {
        case .normal: nil
        case .turbo: "bolt.fill"
        case .toggle: "lock.fill"
        case .macro: "sparkles"
        }
    }

    static func clampedTurboHz(_ hz: Int) -> Int {
        min(max(hz, turboRange.lowerBound), turboRange.upperBound)
    }

    static func turboTitle(_ hz: Int) -> String {
        "\(clampedTurboHz(hz)) presses a second"
    }

    /// The speed menu: the usual choices plus whatever this button already uses.
    static func turboOptions(including hz: Int) -> [Int] {
        Array(Set(turboChoices + [clampedTurboHz(hz)])).sorted()
    }
}

/// What a combo holds down at one moment: buttons and fully pulled triggers. Sticks aren't recorded.
struct MacroFrame: Codable, Equatable, Hashable, Sendable {
    var buttons: Int32
    var leftTrigger: Bool
    var rightTrigger: Bool

    init(buttons: GamepadButtons = [], leftTrigger: Bool = false, rightTrigger: Bool = false) {
        self.buttons = buttons.intersection(.all).rawValue
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    init(_ state: GamepadState) {
        self.init(buttons: state.buttons, leftTrigger: state.leftTrigger > 0.5, rightTrigger: state.rightTrigger > 0.5)
    }

    private enum CodingKeys: String, CodingKey { case buttons, leftTrigger, rightTrigger }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(Int32.self, forKey: .buttons)) ?? 0
        buttons = GamepadButtons(rawValue: raw).intersection(.all).rawValue   // shared files are untrusted
        leftTrigger = (try? c.decodeIfPresent(Bool.self, forKey: .leftTrigger)) ?? false
        rightTrigger = (try? c.decodeIfPresent(Bool.self, forKey: .rightTrigger)) ?? false
    }

    var pressed: GamepadButtons { GamepadButtons(rawValue: buttons) }
    var isEmpty: Bool { buttons == 0 && !leftTrigger && !rightTrigger }
}

struct MacroStep: Codable, Equatable, Hashable, Sendable {
    var frame: MacroFrame
    var seconds: Double
}

/// A recorded combo: what was held, and for how long, step by step.
struct Macro: Codable, Equatable, Hashable, Sendable {
    static let maximumSteps = 64
    /// About one frame at 60 fps: shorter presses might not reach the game.
    static let shortestStep = 0.016
    static let longestStep = 5.0
    static let longestCombo = 15.0

    var steps: [MacroStep]

    init(steps: [MacroStep] = []) {
        self.steps = steps
    }

    var duration: TimeInterval { steps.reduce(0) { $0 + $1.seconds } }
    var isEmpty: Bool { steps.isEmpty }

    /// Each button or trigger that goes down counts as one press.
    var pressCount: Int {
        var count = 0
        var previous = MacroFrame()
        for step in steps {
            count += step.frame.pressed.subtracting(previous.pressed).rawValue.nonzeroBitCount
            if step.frame.leftTrigger, !previous.leftTrigger { count += 1 }
            if step.frame.rightTrigger, !previous.rightTrigger { count += 1 }
            previous = step.frame
        }
        return count
    }

    /// Drops broken steps, keeps each step between `shortestStep` and `longestStep`, and the whole combo
    /// within `maximumSteps` and `longestCombo`.
    func sanitized() -> Macro {
        var kept: [MacroStep] = []
        var total = 0.0
        for step in steps where step.seconds.isFinite {
            guard kept.count < Self.maximumSteps else { break }
            let seconds = min(max(step.seconds, Self.shortestStep), Self.longestStep)
            guard total + seconds <= Self.longestCombo + 1e-9 else { break }
            kept.append(MacroStep(frame: step.frame, seconds: seconds))
            total += seconds
        }
        return Macro(steps: kept)
    }

    /// What is held `elapsed` seconds in, or nil once the combo is over.
    func frame(at elapsed: TimeInterval) -> MacroFrame? {
        guard elapsed >= 0 else { return nil }
        var start = 0.0
        for step in steps {
            if elapsed < start + step.seconds { return step.frame }
            start += step.seconds
        }
        return nil
    }

    /// When the next step starts (or the combo ends), counted from the start; nil when it's over.
    func nextBoundary(after elapsed: TimeInterval) -> TimeInterval? {
        var end = 0.0
        for step in steps {
            end += step.seconds
            if end > elapsed { return end }
        }
        return nil
    }

    /// "2 presses · 0.4 seconds".
    func summary(locale: Locale = .current) -> String {
        let presses = pressCount == 1 ? "1 press" : "\(pressCount) presses"
        let seconds = duration.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return "\(presses) · \(seconds) \(seconds == "1" ? "second" : "seconds")"
    }
}

/// What a special button presses.
enum PressTarget: Equatable, Hashable, Sendable {
    case button(GamepadButtons)
    case trigger(left: Bool)
}

/// Everything the engine needs to know about one special button.
struct SpecialBinding: Equatable, Sendable {
    var target: PressTarget
    var behavior: ButtonBehavior
    var turboHz: Int
    var macro: Macro?

    init(target: PressTarget, behavior: ButtonBehavior, turboHz: Int = ButtonBehavior.defaultTurboHz,
         macro: Macro? = nil) {
        self.target = target
        self.behavior = behavior
        self.turboHz = turboHz
        self.macro = macro
    }
}

/// What all special buttons hold down right now, added on top of the touch pad.
struct SpecialOutput: Equatable, Sendable {
    var buttons: GamepadButtons = []
    var leftTrigger = false
    var rightTrigger = false

    static let empty = SpecialOutput()

    mutating func press(_ target: PressTarget) {
        switch target {
        case .button(let flag): buttons.formUnion(flag)
        case .trigger(let left):
            if left { leftTrigger = true } else { rightTrigger = true }
        }
    }

    mutating func add(_ frame: MacroFrame) {
        buttons.formUnion(frame.pressed)
        leftTrigger = leftTrigger || frame.leftTrigger
        rightTrigger = rightTrigger || frame.rightTrigger
    }
}

/// Turbo, tap-to-hold and combos as pure timing: given a clock reading, says what is held and when that
/// next changes. The caller owns the clock and the timer, so tests can step through time exactly.
struct SpecialButtonEngine: Sendable {
    private enum Activity: Sendable {
        case turbo(SpecialBinding, since: TimeInterval)
        case latched(SpecialBinding)
        case combo(Macro, since: TimeInterval)
    }

    private var activities: [UUID: Activity] = [:]

    var isIdle: Bool { activities.isEmpty }

    /// Tap-to-hold buttons that are held right now.
    var latchedIDs: Set<UUID> {
        Set(activities.compactMap { id, activity in
            if case .latched = activity { return id }
            return nil
        })
    }

    /// A finger went down on a special button.
    mutating func press(_ id: UUID, _ binding: SpecialBinding, at now: TimeInterval) {
        switch binding.behavior {
        case .normal:
            return
        case .turbo:
            activities[id] = .turbo(binding, since: now)
        case .toggle:
            if case .latched = activities[id] { activities[id] = nil } else { activities[id] = .latched(binding) }
        case .macro:
            guard let macro = binding.macro?.sanitized(), !macro.isEmpty else { return }
            activities[id] = .combo(macro, since: now)   // pressing again starts it over
        }
    }

    /// The finger lifted. Only turbo stops: a hold waits for the next tap, a combo plays to its end.
    mutating func release(_ id: UUID) {
        if case .turbo = activities[id] { activities[id] = nil }
    }

    /// Forgets combos that have finished.
    mutating func expire(at now: TimeInterval) {
        activities = activities.filter { _, activity in
            if case .combo(let macro, let since) = activity { return now - since < macro.duration }
            return true
        }
    }

    mutating func reset() {
        activities = [:]
    }

    func output(at now: TimeInterval) -> SpecialOutput {
        var out = SpecialOutput()
        for activity in activities.values {
            switch activity {
            case .turbo(let binding, let since):
                if Self.turboIsDown(since: since, hz: binding.turboHz, at: now) { out.press(binding.target) }
            case .latched(let binding):
                out.press(binding.target)
            case .combo(let macro, let since):
                if let frame = macro.frame(at: now - since) { out.add(frame) }
            }
        }
        return out
    }

    /// When the output next changes, always after `now`; nil when nothing is timed.
    func nextChange(after now: TimeInterval) -> TimeInterval? {
        var soonest: TimeInterval?
        for activity in activities.values {
            let next: TimeInterval?
            switch activity {
            case .turbo(let binding, let since):
                next = Self.nextTurboFlip(since: since, hz: binding.turboHz, after: now)
            case .latched:
                next = nil
            case .combo(let macro, let since):
                next = macro.nextBoundary(after: now - since).map { since + $0 }
            }
            if let next {
                let future = max(next, now + 0.001)   // never "now": rounding must not stall a timer
                soonest = min(soonest ?? future, future)
            }
        }
        return soonest
    }

    /// Down for the first half of each cycle, starting the moment it's pressed.
    private static func turboIsDown(since: TimeInterval, hz: Int, at now: TimeInterval) -> Bool {
        let cycles = max(now - since, 0) * Double(ButtonBehavior.clampedTurboHz(hz))
        return cycles - cycles.rounded(.down) < 0.5
    }

    private static func nextTurboFlip(since: TimeInterval, hz: Int, after now: TimeInterval) -> TimeInterval {
        let half = 0.5 / Double(ButtonBehavior.clampedTurboHz(hz))
        let halves = (max(now - since, 0) / half).rounded(.down) + 1
        let next = since + halves * half
        return next > now ? next : next + half
    }
}
