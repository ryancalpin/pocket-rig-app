/// Decides whether the deck should treat a physical controller as connected.
/// Restarting the stream for a new size stops the controller monitor, which briefly reports "no controller".
/// That must not reach the deck, so while reconnecting the deck keeps what it had.
enum ControllerPresence {
    static func resolve(current: Bool, isStreaming: Bool, monitorHasController: Bool,
                        padConnected: Bool, isReconnecting: Bool) -> Bool {
        if isReconnecting { return current }
        return isStreaming ? monitorHasController : padConnected
    }
}
