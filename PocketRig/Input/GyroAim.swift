import CMoonlight
import Foundation

/// Which way up the picture is, so rotation can be read in the player's terms.
enum GyroOrientation: Sendable, Equatable, CaseIterable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// The screen's right and up directions in the phone's own axes (x toward the right edge and y toward
    /// the top edge when held upright in portrait; z out of the screen).
    var axes: (right: SIMD3<Double>, up: SIMD3<Double>) {
        switch self {
        case .portrait: ([1, 0, 0], [0, 1, 0])
        case .portraitUpsideDown: ([-1, 0, 0], [0, -1, 0])
        case .landscapeRight: ([0, -1, 0], [1, 0, 0])
        case .landscapeLeft: ([0, 1, 0], [-1, 0, 0])
        }
    }
}

/// One motion reading from the phone.
struct GyroSample: Sendable, Equatable {
    /// Radians a second, phone axes.
    var rotationRate: SIMD3<Double>
    /// In g, phone axes, pointing down.
    var gravity: SIMD3<Double>
}

/// How fast the player is aiming, in degrees a second: x = turning right, y = tipping the top away (up).
/// Turning is measured around real "up" (from gravity), so it works held upright, flat, or half-folded.
enum GyroAim {
    /// Slower than this is a steady hand, not aiming.
    static let deadZone = 1.0

    static func aimRate(_ sample: GyroSample, orientation: GyroOrientation) -> SIMD2<Double> {
        let (right, screenUp) = orientation.axes
        let g = sample.gravity
        let length = (g * g).sum().squareRoot()
        let worldUp = length > 0.3 ? -g / length : screenUp
        let degreesPerRadian = 180 / Double.pi
        let yaw = -(sample.rotationRate * worldUp).sum() * degreesPerRadian
        let pitch = (sample.rotationRate * right).sum() * degreesPerRadian
        return [abs(yaw) < deadZone ? 0 : yaw, abs(pitch) < deadZone ? 0 : pitch]
    }
}

/// Aim speed → right-stick position. Games ignore small stick moves, so any real aim starts just past
/// that ("anti-dead-zone").
enum GyroStickMapper {
    /// Degrees a second for a full stick at sensitivity 1.
    static let fullSpeed = 120.0
    static let antiDeadZone = 0.12

    static func stick(aim: SIMD2<Double>, sensitivity: Double, invertY: Bool) -> SIMD2<Float> {
        var v = aim * sensitivity / fullSpeed
        if invertY { v.y = -v.y }
        let length = (v * v).sum().squareRoot()
        guard length > 0, length.isFinite else { return .zero }
        let scaled = min(antiDeadZone + length * (1 - antiDeadZone), 1)
        v = v / length * scaled
        return [Float(v.x), Float(v.y)]
    }
}

/// Aim speed → mouse movement in whole pixels; the leftover fraction carries to the next reading.
struct GyroMouseAccumulator: Sendable {
    static let pixelsPerDegree = 10.0
    private var carry = SIMD2<Double>.zero

    mutating func move(aim: SIMD2<Double>, seconds: TimeInterval, sensitivity: Double,
                       invertY: Bool) -> (dx: Int16, dy: Int16)? {
        guard seconds > 0, seconds < 0.1 else { return nil }   // first reading, or a pause: not motion
        var delta = aim * seconds * Self.pixelsPerDegree * sensitivity
        if invertY { delta.y = -delta.y }
        let total = carry + SIMD2(delta.x, -delta.y)   // screen y grows downward
        let whole = total.rounded(.towardZero)
        carry = total - whole
        guard whole != .zero else { return nil }
        return (Int16(clamping: Int(whole.x)), Int16(clamping: Int(whole.y)))
    }

    mutating func reset() {
        carry = .zero
    }
}

/// A controller's motion in the units the PC expects (moonlight `LI_MOTION_TYPE_*`).
enum MotionConversion {
    static let standardGravity = 9.80665

    /// Radians a second → degrees a second.
    static func gyro(_ rate: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(rate * (180 / Double.pi))
    }

    /// Acceleration in g (gravity included, pointing down) → m/s² reading +9.8 upward at rest, like a
    /// real sensor.
    static func acceleration(_ g: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(-g * standardGravity)
    }
}

/// What the PC asked for: each sensor's report rate; 0 means off.
struct MotionRequests: Sendable, Equatable {
    private(set) var accelHz: UInt16 = 0
    private(set) var gyroHz: UInt16 = 0

    mutating func apply(type: UInt8, rateHz: UInt16) {
        switch type {
        case UInt8(LI_MOTION_TYPE_ACCEL): accelHz = rateHz
        case UInt8(LI_MOTION_TYPE_GYRO): gyroHz = rateHz
        default: break
        }
    }

    var isActive: Bool { accelHz > 0 || gyroHz > 0 }

    /// How often to report, kept between 30 and 200 a second.
    var rateHz: Double {
        isActive ? min(max(Double(max(accelHz, gyroHz)), 30), 200) : 0
    }

    mutating func reset() {
        self = MotionRequests()
    }
}
