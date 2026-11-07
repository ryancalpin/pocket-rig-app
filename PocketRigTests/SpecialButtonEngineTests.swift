import Foundation
import Testing
@testable import PocketRig

@Suite struct SpecialButtonEngineTests {
    private let a = UUID(), b = UUID()
    private let t0: TimeInterval = 100

    private func combo(_ steps: [(GamepadButtons, Double)]) -> Macro {
        Macro(steps: steps.map { MacroStep(frame: MacroFrame(buttons: $0.0), seconds: $0.1) })
    }

    @Test func turboFlipsWhileHeld() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .turbo, turboHz: 10), at: t0)
        #expect(e.output(at: t0).buttons == .a)
        #expect(e.output(at: t0 + 0.06).buttons.isEmpty)
        #expect(e.output(at: t0 + 0.11).buttons == .a)
        #expect(approximately(e.nextChange(after: t0) ?? -1, t0 + 0.05))
        #expect(approximately(e.nextChange(after: t0 + 0.06) ?? -1, t0 + 0.10))
    }

    @Test func turboStopsWhenLetGo() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .turbo), at: t0)
        e.release(a)
        #expect(e.output(at: t0 + 0.01) == .empty)
        #expect(e.nextChange(after: t0) == nil)
        #expect(e.isIdle)
    }

    @Test func tapToHoldLatchesUntilTheNextTap() {
        var e = SpecialButtonEngine()
        let binding = SpecialBinding(target: .button(.b), behavior: .toggle)
        e.press(a, binding, at: t0)
        e.release(a)
        #expect(e.output(at: t0 + 5).buttons == .b)
        #expect(e.latchedIDs == [a])
        #expect(e.nextChange(after: t0) == nil)   // nothing timed
        e.press(a, binding, at: t0 + 6)
        e.release(a)
        #expect(e.output(at: t0 + 6).buttons.isEmpty)
        #expect(e.latchedIDs.isEmpty)
    }

    @Test func aComboPlaysToTheEndEvenAfterLettingGo() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.y), behavior: .macro, macro: combo([(.a, 0.1), ([], 0.1), (.b, 0.2)])),
                at: t0)
        e.release(a)
        #expect(e.output(at: t0).buttons == .a)
        #expect(e.output(at: t0 + 0.15).buttons.isEmpty)
        #expect(e.output(at: t0 + 0.3).buttons == .b)
        #expect(approximately(e.nextChange(after: t0 + 0.3) ?? -1, t0 + 0.4))
        e.expire(at: t0 + 0.5)
        #expect(e.isIdle)
        #expect(e.output(at: t0 + 0.5) == .empty)
    }

    @Test func pressingAComboAgainRestartsIt() {
        var e = SpecialButtonEngine()
        let binding = SpecialBinding(target: .button(.y), behavior: .macro, macro: combo([(.a, 0.1), (.b, 0.1)]))
        e.press(a, binding, at: t0)
        e.press(a, binding, at: t0 + 0.15)
        #expect(e.output(at: t0 + 0.16).buttons == .a)
    }

    @Test func anEmptyComboDoesNothing() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.y), behavior: .macro), at: t0)
        #expect(e.isIdle)
        e.press(a, SpecialBinding(target: .button(.y), behavior: .macro, macro: Macro()), at: t0)
        #expect(e.isIdle)
    }

    @Test func triggersCanBeSpecialToo() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .trigger(left: false), behavior: .toggle), at: t0)
        #expect(e.output(at: t0) == SpecialOutput(rightTrigger: true))
    }

    @Test func severalSpecialButtonsAddUp() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .toggle), at: t0)
        e.press(b, SpecialBinding(target: .button(.x), behavior: .turbo, turboHz: 10), at: t0)
        #expect(e.output(at: t0).buttons == [.a, .x])
        #expect(e.output(at: t0 + 0.06).buttons == .a)
    }

    @Test func normalButtonsAreNotTheEnginesJob() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .normal), at: t0)
        #expect(e.isIdle)
    }

    @Test func resetLetsGoOfEverything() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .toggle), at: t0)
        e.press(b, SpecialBinding(target: .button(.x), behavior: .turbo), at: t0)
        e.reset()
        #expect(e.isIdle)
        #expect(e.output(at: t0) == .empty)
    }

    @Test func theNextChangeIsAlwaysInTheFuture() {
        var e = SpecialButtonEngine()
        e.press(a, SpecialBinding(target: .button(.a), behavior: .turbo, turboHz: 10), at: t0)
        let flip = t0 + 0.05
        #expect((e.nextChange(after: flip) ?? 0) > flip)
    }
}
