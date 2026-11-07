/// What a control sends to the PC.
enum ControlInput: Equatable, Sendable {
    case button(GamepadButtons)
    case trigger(left: Bool)
    case stick(left: Bool)
    case dpad
}

/// What a control shows: a letter/word, or an SF Symbol, plus its VoiceOver name.
struct ControlFace: Equatable, Sendable {
    var title: String?
    var symbol: String?
    var name: String
}

/// Button labels to match the controller the player knows. The PC always sees an Xbox pad.
enum ControllerStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case xbox, playStation, nintendo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xbox: "Xbox"
        case .playStation: "PlayStation"
        case .nintendo: "Nintendo"
        }
    }

    /// Nintendo swaps A/B and X/Y: the button *labelled* A sends A, wherever it sits.
    func input(for kind: ControlKind) -> ControlInput {
        switch kind {
        case .faceSouth: .button(self == .nintendo ? .b : .a)
        case .faceEast: .button(self == .nintendo ? .a : .b)
        case .faceWest: .button(self == .nintendo ? .y : .x)
        case .faceNorth: .button(self == .nintendo ? .x : .y)
        case .dpad: .dpad
        case .leftStick: .stick(left: true)
        case .rightStick: .stick(left: false)
        case .leftStickClick: .button(.leftStick)
        case .rightStickClick: .button(.rightStick)
        case .leftBumper: .button(.leftBumper)
        case .rightBumper: .button(.rightBumper)
        case .leftTrigger: .trigger(left: true)
        case .rightTrigger: .trigger(left: false)
        case .back: .button(.back)
        case .start: .button(.start)
        case .guide: .button(.guide)
        }
    }

    func face(for kind: ControlKind) -> ControlFace {
        switch kind {
        case .faceSouth, .faceEast, .faceWest, .faceNorth: faceButton(kind)
        case .dpad: ControlFace(title: nil, symbol: nil, name: "D-pad")
        case .leftStick: ControlFace(title: nil, symbol: nil, name: "Left stick")
        case .rightStick: ControlFace(title: nil, symbol: nil, name: "Right stick")
        case .leftStickClick: ControlFace(title: self == .playStation ? "L3" : "LS", symbol: nil, name: "Left stick press")
        case .rightStickClick: ControlFace(title: self == .playStation ? "R3" : "RS", symbol: nil, name: "Right stick press")
        case .leftBumper: shoulder(xbox: "LB", playStation: "L1", nintendo: "L", name: "Left bumper")
        case .rightBumper: shoulder(xbox: "RB", playStation: "R1", nintendo: "R", name: "Right bumper")
        case .leftTrigger: shoulder(xbox: "LT", playStation: "L2", nintendo: "ZL", name: "Left trigger")
        case .rightTrigger: shoulder(xbox: "RT", playStation: "R2", nintendo: "ZR", name: "Right trigger")
        case .back: ControlFace(title: nil, symbol: self == .nintendo ? "minus" : "rectangle.on.rectangle", name: "Back button")
        case .start: ControlFace(title: nil, symbol: self == .nintendo ? "plus" : "line.3.horizontal", name: "Start button")
        case .guide: ControlFace(title: nil, symbol: "house.fill", name: "Guide button")
        }
    }

    private func shoulder(xbox: String, playStation: String, nintendo: String, name: String) -> ControlFace {
        let title = switch self {
        case .xbox: xbox
        case .playStation: playStation
        case .nintendo: nintendo
        }
        return ControlFace(title: title, symbol: nil, name: name)
    }

    private func faceButton(_ kind: ControlKind) -> ControlFace {
        switch self {
        case .playStation:
            let (symbol, name) = switch kind {
            case .faceSouth: ("xmark", "Cross")
            case .faceEast: ("circle", "Circle")
            case .faceWest: ("square", "Square")
            default: ("triangle", "Triangle")
            }
            return ControlFace(title: nil, symbol: symbol, name: "\(name) button")
        case .xbox, .nintendo:
            let letter = switch (self, kind) {
            case (.xbox, .faceSouth), (.nintendo, .faceEast): "A"
            case (.xbox, .faceEast), (.nintendo, .faceSouth): "B"
            case (.xbox, .faceWest), (.nintendo, .faceNorth): "X"
            default: "Y"
            }
            return ControlFace(title: letter, symbol: nil, name: "\(letter) button")
        }
    }
}
