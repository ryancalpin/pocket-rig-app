enum KeyEvent: Equatable, Sendable {
    case text(String)
    case key(VirtualKey)
}

/// Splits what the phone keyboard typed into text (sent as Unicode) and keys the PC must see as key
/// presses (Return, Tab).
enum KeyboardTranslator {
    static func events(for typed: String) -> [KeyEvent] {
        var events: [KeyEvent] = []
        var run = ""
        func flush() {
            if !run.isEmpty {
                events.append(.text(run))
                run = ""
            }
        }
        for character in typed {
            switch character {
            case "\n", "\r", "\r\n":
                flush()
                events.append(.key(.enter))
            case "\t":
                flush()
                events.append(.key(.tab))
            default:
                run.append(character)
            }
        }
        flush()
        return events
    }
}
