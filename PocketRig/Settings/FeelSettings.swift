import CoreGraphics
import Foundation
import SwiftData

/// How strongly the phone itself vibrates: game rumble, trigger taps, feel-the-sound, and taps on
/// buttons and keys. A connected controller always rumbles at its own full strength.
enum HapticsStrength: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Multiplies every phone vibration. 0 turns them all off.
    var scale: Float {
        switch self {
        case .off: 0
        case .low: 0.4
        case .medium: 0.7
        case .high: 1
        }
    }

    /// Strength of one button or key tap, or nil for no tap at all.
    var tapIntensity: CGFloat? {
        self == .off ? nil : CGFloat(scale)
    }
}

/// What tilting the phone does while streaming.
enum GyroMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, rightStick, mouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .rightStick: "Right stick"
        case .mouse: "Mouse"
        }
    }
}

/// The feel settings as plain values, so every feature can compare them and pass them around freely.
struct FeelSnapshot: Equatable, Sendable {
    var strength: HapticsStrength = .medium
    var feelTheSound = false
    var gyroMode: GyroMode = .off
    var gyroSensitivity: Double = 1
    var gyroInvertY = false

    /// Listening to the game audio only makes sense when the phone may vibrate.
    var listensToSound: Bool { feelTheSound && strength != .off }
}

/// Vibration and tilt-to-aim settings. One record, like `StreamPreferences`; a running stream picks up
/// changes right away.
@Model
final class FeelSettings {
    static let sensitivityRange: ClosedRange<Double> = 0.25...3

    var hapticsStrengthRaw: String = HapticsStrength.medium.rawValue
    var feelTheSound: Bool = false
    var gyroModeRaw: String = GyroMode.off.rawValue
    var gyroSensitivity: Double = 1
    var gyroInvertY: Bool = false

    init() {}

    var hapticsStrength: HapticsStrength {
        get { HapticsStrength(rawValue: hapticsStrengthRaw) ?? .medium }
        set { hapticsStrengthRaw = newValue.rawValue }
    }

    var gyroMode: GyroMode {
        get { GyroMode(rawValue: gyroModeRaw) ?? .off }
        set { gyroModeRaw = newValue.rawValue }
    }

    var snapshot: FeelSnapshot {
        FeelSnapshot(strength: hapticsStrength, feelTheSound: feelTheSound, gyroMode: gyroMode,
                     gyroSensitivity: Self.clampedSensitivity(gyroSensitivity), gyroInvertY: gyroInvertY)
    }

    static func clampedSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    /// "1×", "0.5×", "2.25×".
    static func sensitivityTitle(_ value: Double, locale: Locale = .current) -> String {
        let number = clampedSensitivity(value).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return "\(number)×"
    }

    /// The saved settings, created with defaults the first time.
    @MainActor
    static func current(in context: ModelContext) -> FeelSettings {
        if let saved = try? context.fetch(FetchDescriptor<FeelSettings>()).first { return saved }
        let fresh = FeelSettings()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
