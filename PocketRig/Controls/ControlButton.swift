import CoreGraphics
import Foundation

/// Every control the on-screen gamepad can show.
enum ControlKind: String, Codable, CaseIterable, Sendable {
    /// Face buttons by position (Xbox A is south), so the style decides the letter.
    case faceSouth, faceEast, faceWest, faceNorth
    case dpad
    case leftStick, rightStick
    case leftStickClick, rightStickClick
    case leftBumper, rightBumper
    case leftTrigger, rightTrigger
    case back, start, guide

    /// Round controls stay round when resized.
    var keepsAspect: Bool {
        switch self {
        case .leftBumper, .rightBumper, .leftTrigger, .rightTrigger, .leftStickClick, .rightStickClick: false
        default: true
        }
    }

    /// Sticks and the d-pad are always plain; every button and trigger can be turbo, tap-to-hold or a combo.
    var supportsSpecialBehavior: Bool {
        switch self {
        case .dpad, .leftStick, .rightStick: false
        default: true
        }
    }
}

/// A rectangle as fractions (0…1) of the area it lives in, so one layout fits any screen of that pose.
struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect, in size: CGSize) {
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        self.init(x: Double(rect.minX) / w, y: Double(rect.minY) / h,
                  width: Double(rect.width) / w, height: Double(rect.height) / h)
    }

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * Double(size.width), y: y * Double(size.height),
               width: width * Double(size.width), height: height * Double(size.height))
    }

    /// Repairs a frame read from disk: no NaN or infinity, at most the whole area, and inside it.
    /// Unlike `clamped`, it needs no screen size, so it can run while decoding.
    func sanitized() -> NormalizedRect {
        func fix(_ v: Double, fallback: Double) -> Double { v.isFinite ? v : fallback }
        let w = min(max(fix(width, fallback: 0.1), 0.01), 1)
        let h = min(max(fix(height, fallback: 0.1), 0.01), 1)
        return NormalizedRect(x: min(max(fix(x, fallback: 0), 0), 1 - w),
                              y: min(max(fix(y, fallback: 0), 0), 1 - h), width: w, height: h)
    }

    /// Inside the area, and at least `minimumPoints` wide and tall there.
    func clamped(in size: CGSize, minimumPoints: CGFloat = 44) -> NormalizedRect {
        let minW = size.width > 0 ? min(1, Double(minimumPoints / size.width)) : 0
        let minH = size.height > 0 ? min(1, Double(minimumPoints / size.height)) : 0
        let w = min(max(width, minW), 1)
        let h = min(max(height, minH), 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }
}

/// One control in a layout. Stored as JSON inside `ControlLayout.buttonsData`; every field after `frame`
/// is optional when decoding, and plain buttons are written exactly as Phase 2 wrote them, so older
/// builds and older layouts keep working.
struct ControlButton: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Fainter than this and a button is hard to find again.
    static let minimumOpacity = 0.15

    var id: UUID
    var kind: ControlKind
    var frame: NormalizedRect
    var opacity: Double
    var isHidden: Bool
    /// Turbo, tap-to-hold or combo. Sticks and the d-pad are always `.normal`.
    var behavior: ButtonBehavior
    /// Presses a second, for turbo.
    var turboHz: Int
    /// The recorded combo, for `.macro`.
    var macro: Macro?

    /// What a press does on the pad. A combo with nothing recorded yet acts as a normal button.
    var activeBehavior: ButtonBehavior {
        behavior == .macro && (macro?.isEmpty ?? true) ? .normal : behavior
    }

    init(id: UUID = UUID(), kind: ControlKind, frame: NormalizedRect, opacity: Double = 1, isHidden: Bool = false,
         behavior: ButtonBehavior = .normal, turboHz: Int = ButtonBehavior.defaultTurboHz, macro: Macro? = nil) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.opacity = min(max(opacity, Self.minimumOpacity), 1)
        self.isHidden = isHidden
        self.behavior = kind.supportsSpecialBehavior ? behavior : .normal
        self.turboHz = ButtonBehavior.clampedTurboHz(turboHz)
        self.macro = macro.map { $0.sanitized() }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, opacity, isHidden, behavior, turboHz, macro
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  kind: try c.decode(ControlKind.self, forKey: .kind),
                  frame: try c.decode(NormalizedRect.self, forKey: .frame).sanitized(),
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
                  isHidden: try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
                  // A newer or broken value must not cost the user the whole button.
                  behavior: (try? c.decodeIfPresent(ButtonBehavior.self, forKey: .behavior)) ?? .normal,
                  turboHz: (try? c.decodeIfPresent(Int.self, forKey: .turboHz)) ?? ButtonBehavior.defaultTurboHz,
                  macro: (try? c.decodeIfPresent(Macro.self, forKey: .macro)) ?? nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(frame, forKey: .frame)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(isHidden, forKey: .isHidden)
        // Defaults are left out, so a plain button's JSON is byte-for-byte what Phase 2 wrote.
        if behavior != .normal { try c.encode(behavior, forKey: .behavior) }
        if turboHz != ButtonBehavior.defaultTurboHz { try c.encode(turboHz, forKey: .turboHz) }
        if let macro { try c.encode(macro, forKey: .macro) }
    }
}
