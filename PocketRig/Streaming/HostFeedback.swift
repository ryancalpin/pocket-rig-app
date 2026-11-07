/// What the PC sends back while streaming, besides picture and sound, plus the sound level we measure.
enum HostFeedback: Equatable, Sendable {
    /// Gamepad rumble. Each value (0…65535) holds until the next one; 0 and 0 turns it off.
    case rumble(controller: UInt16, low: UInt16, high: UInt16)
    /// Rumble in the triggers (Xbox One impulse triggers, DualSense).
    case triggerRumble(controller: UInt16, left: UInt16, right: UInt16)
    /// The PC wants motion readings (`LI_MOTION_TYPE_*`) this many times a second; 0 stops them.
    case motionRequest(controller: UInt16, type: UInt8, rateHz: UInt16)
    /// How much bass is in the game audio right now, 0…1 ("feel the sound").
    case soundLevel(Float)
}
