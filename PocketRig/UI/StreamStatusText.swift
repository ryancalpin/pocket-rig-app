/// Plain-language text for each stream state. Raw stage names and codes stay in the log.
enum StreamStatusText {
    /// While the stream reconnects for a new size, or for heat or the network.
    static func refitMessage(for reason: StreamResizeController.Reason) -> String {
        switch reason {
        case .resize: "Fitting the picture to the screen…"
        case .quality: "Adjusting quality…"
        }
    }

    /// Text to show over the video, or nil when nothing should cover it (streaming).
    /// `.idle` reads as connecting: the session exists but hasn't begun yet.
    static func message(for state: StreamState?) -> String? {
        switch state {
        case nil, .idle?, .connecting?:
            return "Connecting to your PC…"
        case .launching?:
            return "Starting the game on your PC…"
        case .streaming?:
            return nil
        case .ended?:
            return "The stream ended."
        case .failed(let failure)?:
            switch failure {
            case .unreachable: return "Can't reach your PC. Check that it's on and connected."
            case .launchRejected: return "Your PC couldn't start the game. It may be open on another device."
            case .startFailed: return "The stream couldn't start. Try again in a moment."
            case .disconnected: return "The stream ended unexpectedly."
            }
        }
    }
}
