import Testing
@testable import PocketRig

@Suite struct StreamStatusTextTests {
    @Test func everyConnectingStageReadsTheSame() {
        for stage in ["Starting", "RTSP handshake", "Video stream", "Audio stream"] {
            #expect(StreamStatusText.message(for: .connecting(stage: stage)) == "Connecting to your PC…")
        }
        #expect(StreamStatusText.message(for: nil) == "Connecting to your PC…")
        #expect(StreamStatusText.message(for: .idle) == "Connecting to your PC…")
    }

    @Test func launchingAndStreaming() {
        #expect(StreamStatusText.message(for: .launching) == "Starting the game on your PC…")
        #expect(StreamStatusText.message(for: .streaming) == nil)
    }

    @Test func failuresAreChosenByCause() {
        #expect(StreamStatusText.message(for: .failed(.unreachable)) == "Can't reach your PC. Check that it's on and connected.")
        #expect(StreamStatusText.message(for: .failed(.launchRejected)) == "Your PC couldn't start the game. It may be open on another device.")
        #expect(StreamStatusText.message(for: .failed(.startFailed)) == "The stream couldn't start. Try again in a moment.")
        #expect(StreamStatusText.message(for: .failed(.disconnected)) == "The stream ended unexpectedly.")
    }

    @Test func noTechnicalTextLeaks() {
        let all: [StreamState] = [.connecting(stage: "RTSP handshake"), .failed(.startFailed), .failed(.disconnected)]
        for state in all {
            let text = StreamStatusText.message(for: state) ?? ""
            #expect(!text.contains("RTSP") && !text.contains("("))
        }
    }

    @Test func audioIsOnByDefault() {
        #expect(StreamSettings.default.audioEnabled)
    }
}
