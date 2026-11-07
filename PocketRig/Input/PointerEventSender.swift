import CMoonlight

/// Values match moonlight's BUTTON_LEFT / BUTTON_MIDDLE / BUTTON_RIGHT.
enum MouseButton: Int32, Sendable {
    case left = 1, middle = 2, right = 3
}

enum PointerEvent: Equatable, Sendable {
    /// Relative movement in screen pixels on the PC.
    case move(dx: Int16, dy: Int16)
    case button(MouseButton, down: Bool)
    /// High-resolution wheel units: 120 is one notch, positive scrolls up.
    case scroll(Int16)
}

/// A Windows virtual-key code (Sunshine translates these for Linux hosts too).
struct VirtualKey: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let backspace = VirtualKey(rawValue: 0x08)
    static let tab = VirtualKey(rawValue: 0x09)
    static let enter = VirtualKey(rawValue: 0x0D)
    static let escape = VirtualKey(rawValue: 0x1B)
    static let left = VirtualKey(rawValue: 0x25)
    static let up = VirtualKey(rawValue: 0x26)
    static let right = VirtualKey(rawValue: 0x27)
    static let down = VirtualKey(rawValue: 0x28)
    static let leftWindows = VirtualKey(rawValue: 0x5B)
    static let volumeMute = VirtualKey(rawValue: 0xAD)
    static let volumeDown = VirtualKey(rawValue: 0xAE)
    static let volumeUp = VirtualKey(rawValue: 0xAF)
}

struct KeyModifiers: OptionSet, Sendable {
    let rawValue: Int8

    static let shift = KeyModifiers(rawValue: Int8(MODIFIER_SHIFT))
    static let control = KeyModifiers(rawValue: Int8(MODIFIER_CTRL))
    static let alt = KeyModifiers(rawValue: Int8(MODIFIER_ALT))
    static let meta = KeyModifiers(rawValue: Int8(MODIFIER_META))
}

/// Mouse and keyboard input to the PC. Every call sends right away.
protocol PointerEventSending: Sendable {
    func send(_ event: PointerEvent)
    func sendKey(_ key: VirtualKey, down: Bool, modifiers: KeyModifiers)
    func sendText(_ text: String)
}

extension PointerEventSending {
    /// Press and release.
    func tapKey(_ key: VirtualKey, modifiers: KeyModifiers = []) {
        sendKey(key, down: true, modifiers: modifiers)
        sendKey(key, down: false, modifiers: modifiers)
    }
}

struct MoonlightPointerSender: PointerEventSending {
    func send(_ event: PointerEvent) {
        switch event {
        case .move(let dx, let dy):
            _ = LiSendMouseMoveEvent(dx, dy)
        case .button(let button, let down):
            _ = LiSendMouseButtonEvent(Int8(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), button.rawValue)
        case .scroll(let amount):
            _ = LiSendHighResScrollEvent(amount)
        }
    }

    func sendKey(_ key: VirtualKey, down: Bool, modifiers: KeyModifiers) {
        // Moonlight clients set the high bit on virtual-key codes; Sunshine keeps only the low byte.
        _ = LiSendKeyboardEvent(Int16(bitPattern: 0x8000 | UInt16(key.rawValue)),
                                Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), modifiers.rawValue)
    }

    func sendText(_ text: String) {
        for chunk in TextChunker.chunks(of: text) {
            let length = chunk.utf8.count
            chunk.withCString { _ = LiSendUtf8TextEvent($0, UInt32(length)) }
        }
    }
}

/// Moonlight accepts at most 32 bytes of text per call.
enum TextChunker {
    static let maxBytes = 32

    /// Pieces of at most `maxBytes` UTF-8 bytes, split between characters. A single character that is too
    /// big on its own (a very long emoji sequence) is split between its scalars instead.
    static func chunks(of text: String, maxBytes: Int = TextChunker.maxBytes) -> [String] {
        var result: [String] = []
        var current = ""
        var used = 0
        func add(_ piece: String, bytes: Int) {
            if used + bytes > maxBytes, !current.isEmpty {
                result.append(current)
                current = ""
                used = 0
            }
            current += piece
            used += bytes
        }
        for character in text {
            let bytes = character.utf8.count
            if bytes <= maxBytes {
                add(String(character), bytes: bytes)
            } else {
                for scalar in character.unicodeScalars {
                    add(String(scalar), bytes: String(scalar).utf8.count)
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// For previews and the debug stream screen.
struct NoOpPointerSender: PointerEventSending {
    func send(_ event: PointerEvent) {}
    func sendKey(_ key: VirtualKey, down: Bool, modifiers: KeyModifiers) {}
    func sendText(_ text: String) {}
}
