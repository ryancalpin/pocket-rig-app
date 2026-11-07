/// Vibration strength per channel, 0…1. The phone has one motor; "heavy" plays deep and soft,
/// "light" sharp and crisp, and both can play at once.
struct PhoneLevels: Equatable, Sendable {
    var heavy: Float = 0
    var light: Float = 0

    static let zero = PhoneLevels()

    var isZero: Bool { heavy == 0 && light == 0 }
}

/// Turns rumble, the sound level and the settings into how hard each phone channel vibrates.
/// Pure, so the feel can be tested without hardware.
enum FeelMixer {
    /// Below this a level is noise, not rumble.
    static let noiseFloor: Float = 0.02
    /// Feel-the-sound plays a little under full strength, so real rumble always stands out.
    static let soundShare: Float = 0.8

    /// Motor speed (0…65535) to a level (0…1). A square root, because gentle rumble feels weaker on
    /// a phone than its number suggests.
    static func motorLevel(_ raw: UInt16) -> Float {
        let level = (Float(raw) / Float(UInt16.max)).squareRoot()
        return level < noiseFloor ? 0 : min(level, 1)
    }

    /// What the phone plays.
    /// - controllerTakesRumble: a connected controller can rumble, so game rumble goes there instead.
    /// - controllerAttached: any controller is connected; feel-the-sound then stays off.
    static func phone(low: UInt16, high: UInt16, sound: Float, settings: FeelSnapshot,
                      controllerTakesRumble: Bool, controllerAttached: Bool) -> PhoneLevels {
        let scale = settings.strength.scale
        guard scale > 0 else { return .zero }
        let heavy = motorLevel(low), light = motorLevel(high)
        let rumbling = heavy > 0 || light > 0
        if rumbling, !controllerTakesRumble {
            return PhoneLevels(heavy: heavy * scale, light: light * scale)
        }
        guard settings.feelTheSound, !controllerAttached, !rumbling else { return .zero }
        let level = min(max(sound.isFinite ? sound : 0, 0), 1)
        return level < noiseFloor ? .zero : PhoneLevels(heavy: level * soundShare * scale, light: 0)
    }

    /// What a controller's motors play: the game's own values, unscaled.
    static func controller(low: UInt16, high: UInt16) -> PhoneLevels {
        PhoneLevels(heavy: motorLevel(low), light: motorLevel(high))
    }
}
