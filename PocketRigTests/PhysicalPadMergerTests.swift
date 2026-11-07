import Testing
@testable import PocketRig

/// The Quick menu's Steam button with a physical pad connected must not wipe what the player is holding.
@Suite struct PhysicalPadMergerTests {
    private func holding() -> GamepadState {
        var s = GamepadState()
        s.buttons = [.a]
        s.leftTrigger = 0.8
        s.leftStick = [0.5, -0.25]
        return s
    }

    @Test func aHeldButtonIsAddedOnTopOfThePhysicalState() {
        let merger = PhysicalPadMerger()
        _ = merger.physicalChanged(holding())
        let pressed = merger.hold(.guide)
        #expect(pressed.buttons == [.a, .guide])
        #expect(pressed.leftTrigger == 0.8)
        #expect(pressed.leftStick == [0.5, -0.25])
    }

    @Test func releasingGoesBackToWhatThePadIsDoingNow() {
        let merger = PhysicalPadMerger()
        _ = merger.physicalChanged(holding())
        _ = merger.hold(.guide)
        var moved = holding()
        moved.rightTrigger = 1
        #expect(merger.physicalChanged(moved).buttons == [.a, .guide])   // still held while the pad moves
        let released = merger.release(.guide)
        #expect(released == moved)
    }

    @Test func resetForgetsEverything() {
        let merger = PhysicalPadMerger()
        _ = merger.physicalChanged(holding())
        _ = merger.hold(.guide)
        merger.reset()
        #expect(merger.hold(.start) == { var s = GamepadState(); s.buttons = [.start]; return s }())
    }
}

@Suite @MainActor struct SteamButtonRoutingTests {
    @Test func withoutAPadTheTouchGamepadTapsGuide() async {
        let sender = RecordingSender()
        let model = DeckModel(gamepad: GamepadInput(sender: sender))
        var physicalTaps: [GamepadButtons] = []
        model.onPhysicalTap = { physicalTaps.append($0) }
        model.tapSteamButton()
        #expect(sender.sent.first?.buttons == [.guide])
        #expect(physicalTaps.isEmpty)
    }

    @Test func withAPadTheTapGoesThroughThePadsState() {
        let sender = RecordingSender()
        let model = DeckModel(gamepad: GamepadInput(sender: sender))
        var physicalTaps: [GamepadButtons] = []
        model.onPhysicalTap = { physicalTaps.append($0) }
        model.controllerChanged(true)
        model.tapSteamButton()
        #expect(physicalTaps == [.guide])
        #expect(sender.sent.isEmpty)   // the touch pad's all-zero state never reaches slot 0
    }
}
