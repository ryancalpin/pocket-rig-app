import Testing
@testable import PocketRig

@Suite struct ControllerPresenceTests {
    @Test func reconnectingKeepsWhatTheDeckHad() {
        // The monitor stops during a resize reconnect and reports no pad; the deck must not follow.
        #expect(ControllerPresence.resolve(current: true, isStreaming: true, monitorHasController: false,
                                           padConnected: false, isReconnecting: true))
        #expect(!ControllerPresence.resolve(current: false, isStreaming: true, monitorHasController: true,
                                            padConnected: true, isReconnecting: true))
    }

    @Test func streamingFollowsTheMonitor() {
        #expect(ControllerPresence.resolve(current: false, isStreaming: true, monitorHasController: true,
                                           padConnected: false, isReconnecting: false))
        #expect(!ControllerPresence.resolve(current: true, isStreaming: true, monitorHasController: false,
                                            padConnected: true, isReconnecting: false))
    }

    @Test func beforeStreamingFollowsTheConnectedPads() {
        #expect(ControllerPresence.resolve(current: false, isStreaming: false, monitorHasController: false,
                                           padConnected: true, isReconnecting: false))
    }
}
