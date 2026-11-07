import CMoonlight

struct GamepadButtons: OptionSet, Sendable, Hashable {
    let rawValue: Int32

    static let a = GamepadButtons(rawValue: Int32(A_FLAG))
    static let b = GamepadButtons(rawValue: Int32(B_FLAG))
    static let x = GamepadButtons(rawValue: Int32(X_FLAG))
    static let y = GamepadButtons(rawValue: Int32(Y_FLAG))
    static let up = GamepadButtons(rawValue: Int32(UP_FLAG))
    static let down = GamepadButtons(rawValue: Int32(DOWN_FLAG))
    static let left = GamepadButtons(rawValue: Int32(LEFT_FLAG))
    static let right = GamepadButtons(rawValue: Int32(RIGHT_FLAG))
    static let leftBumper = GamepadButtons(rawValue: Int32(LB_FLAG))
    static let rightBumper = GamepadButtons(rawValue: Int32(RB_FLAG))
    static let start = GamepadButtons(rawValue: Int32(PLAY_FLAG))
    static let back = GamepadButtons(rawValue: Int32(BACK_FLAG))
    static let leftStick = GamepadButtons(rawValue: Int32(LS_CLK_FLAG))
    static let rightStick = GamepadButtons(rawValue: Int32(RS_CLK_FLAG))
    static let guide = GamepadButtons(rawValue: Int32(SPECIAL_FLAG))

    /// Every button this client can report (used for the arrival event).
    static let all: GamepadButtons = [
        .a, .b, .x, .y, .up, .down, .left, .right, .leftBumper, .rightBumper,
        .start, .back, .leftStick, .rightStick, .guide,
    ]
}

struct WireValues: Equatable, Sendable {
    var buttons: Int32, lt: UInt8, rt: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16
}

struct GamepadState: Equatable, Sendable {
    var buttons: GamepadButtons = []
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    /// -1...1, +y = up.
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero

    /// The wire values as an Equatable struct, for change detection.
    var wireValues: WireValues {
        let w = wire
        return WireValues(buttons: w.buttons, lt: w.lt, rt: w.rt, lx: w.lx, ly: w.ly, rx: w.rx, ry: w.ry)
    }

    var wire: (buttons: Int32, lt: UInt8, rt: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16) {
        (
            buttons.rawValue,
            Self.trigger(leftTrigger), Self.trigger(rightTrigger),
            Self.axis(leftStick.x), Self.axis(leftStick.y),
            Self.axis(rightStick.x), Self.axis(rightStick.y)
        )
    }

    private static func trigger(_ v: Float) -> UInt8 {
        UInt8(max(0, min(1, v)) * 255)
    }

    private static func axis(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * 32767)
    }
}
