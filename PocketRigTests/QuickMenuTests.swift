import Testing
@testable import PocketRig

@Suite @MainActor struct QuickMenuTests {
    @Test func guideTapPressesThenLetsGo() async throws {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender)
        input.tap(.guide)
        #expect(sender.sent.last?.buttons == [.guide])
        try await Task.sleep(for: .milliseconds(300))
        #expect(sender.sent.last?.buttons == [])
    }

    @Test func noFrameMeansNothingToSave() async {
        #expect(await FrameCapture.saveCurrentFrame(from: VideoRenderer()) == .nothingToSave)
    }

    @Test func screenshotMessagesArePlain() {
        #expect(ScreenshotResult.saved.message == "Saved to Photos")
        #expect(ScreenshotResult.nothingToSave.message == "Nothing on screen to save yet.")
        #expect(ScreenshotResult.noPermission.message.contains("Settings"))
    }
}
