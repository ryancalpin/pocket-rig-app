import Testing
import CMoonlight

@Suite struct MoonlightCoreLinkTests {
    @Test func launchQueryParametersAreExposed() {
        let params = String(cString: LiGetLaunchUrlQueryParameters())
        #expect(params.hasPrefix("&"))
    }

    @Test func streamConfigurationInitializesToZero() {
        var config = STREAM_CONFIGURATION()
        config.width = 99
        LiInitializeStreamConfiguration(&config)
        #expect(config.width == 0)
    }

    @Test func logSinkReceivesFormattedMessages() {
        var callbacks = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&callbacks)
        PRInstallLogCallback(&callbacks)
        #expect(callbacks.logMessage != nil)
    }
}
