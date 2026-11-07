import Foundation
import Testing
@testable import PocketRig

@Suite @MainActor struct SpecialButtonInputTests {
    private let id = UUID()

    private func make() -> (GamepadInput, RecordingSender, FakeClock) {
        let sender = RecordingSender(), clock = FakeClock()
        return (GamepadInput(sender: sender, now: { clock.now }, schedulesWakeups: false), sender, clock)
    }

    @Test func turboRapidFiresWhileHeld() {
        let (input, sender, clock) = make()
        let binding = SpecialBinding(target: .button(.a), behavior: .turbo, turboHz: 10)
        input.special(id, binding, down: true)
        #expect(sender.sent.last?.buttons == .a)
        clock.now += 0.06
        input.advanceSpecial()
        #expect(sender.sent.last?.buttons == [])
        clock.now += 0.05
        input.advanceSpecial()
        #expect(sender.sent.last?.buttons == .a)
        input.special(id, binding, down: false)
        #expect(sender.sent.last?.buttons == [])
    }

    @Test func tapToHoldStaysDownAndLightsUp() {
        let (input, sender, _) = make()
        let binding = SpecialBinding(target: .button(.b), behavior: .toggle)
        input.special(id, binding, down: true)
        input.special(id, binding, down: false)
        #expect(sender.sent.last?.buttons == .b)
        #expect(input.latchedIDs == [id])
        input.special(id, binding, down: true)
        input.special(id, binding, down: false)
        #expect(sender.sent.last?.buttons == [])
        #expect(input.latchedIDs.isEmpty)
    }

    @Test func aComboPlaysOnItsOwn() {
        let (input, sender, clock) = make()
        let macro = Macro(steps: [MacroStep(frame: MacroFrame(buttons: .a), seconds: 0.1),
                                  MacroStep(frame: MacroFrame(buttons: .b), seconds: 0.1)])
        let binding = SpecialBinding(target: .button(.y), behavior: .macro, macro: macro)
        input.special(id, binding, down: true)
        input.special(id, binding, down: false)
        #expect(sender.sent.last?.buttons == .a)
        clock.now += 0.15
        input.advanceSpecial()
        #expect(sender.sent.last?.buttons == .b)
        clock.now += 0.1
        input.advanceSpecial()
        #expect(sender.sent.last?.buttons == [])
    }

    @Test func specialButtonsAddToWhatYourFingersHold() {
        let (input, sender, _) = make()
        input.update { $0.buttons.insert(.x) }
        input.special(id, SpecialBinding(target: .trigger(left: true), behavior: .toggle), down: true)
        #expect(sender.sent.last?.buttons == .x)
        #expect(sender.sent.last?.leftTrigger == 1)
        #expect(input.touchState.leftTrigger == 0)   // the touch state stays what the fingers do
    }

    @Test func releaseAllLetsGoOfHeldSpecials() {
        let (input, sender, _) = make()
        input.special(id, SpecialBinding(target: .button(.b), behavior: .toggle), down: true)
        input.releaseAll()
        #expect(sender.sent.last?.buttons == [])
        #expect(input.latchedIDs.isEmpty)
    }

    @Test func tiltAddsToTheTouchStick() {
        let (input, sender, _) = make()
        input.update { $0.rightStick = [0.5, 0] }
        input.setGyroStick([0.75, 0.25])
        #expect(sender.sent.last?.rightStick == [1, 0.25])   // added, then kept within the stick's range
        let count = sender.sent.count
        input.setGyroStick([0.75, 0.25])
        #expect(sender.sent.count == count)   // no change, nothing sent
        input.setGyroStick(.zero)
        #expect(sender.sent.last?.rightStick == [0.5, 0])
    }

    @Test func mergeLeavesTheStickAloneWithoutTilt() {
        var touch = GamepadState()
        touch.rightStick = [0.3, -0.2]
        let merged = GamepadInput.merge(touch: touch, special: .empty, gyro: .zero)
        #expect(merged == touch)
    }
}
