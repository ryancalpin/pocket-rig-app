import GameController
import Testing
@testable import PocketRig

@Suite @MainActor struct ControllerRumbleTests {
    @Test func twoHandlesSplitHeavyAndLight() {
        let plan = ControllerHapticsPlan.make(localities: [.default, .all, .handles, .leftHandle, .rightHandle])
        #expect(plan.heavy == .leftHandle)   // the big motor sits in the left grip on Xbox and PlayStation pads
        #expect(plan.light == .rightHandle)
        #expect(!plan.hasTriggerMotors)
    }

    @Test func oneMotorPlaysBoth() {
        #expect(ControllerHapticsPlan.make(localities: [.default, .all, .handles])
                == ControllerHapticsPlan(heavy: .handles))
        #expect(ControllerHapticsPlan.make(localities: [.default, .all])
                == ControllerHapticsPlan(heavy: .default))
    }

    @Test func triggerMotorsAreFound() {
        let both = ControllerHapticsPlan.make(localities: [.default, .handles, .triggers, .leftTrigger, .rightTrigger])
        #expect(both.leftTrigger == .leftTrigger)
        #expect(both.rightTrigger == .rightTrigger)
        #expect(both.hasTriggerMotors)
        let shared = ControllerHapticsPlan.make(localities: [.default, .triggers])
        #expect(shared.leftTrigger == .triggers)
        #expect(shared.rightTrigger == nil)
        #expect(shared.hasTriggerMotors)
    }

    @Test func aPadWithoutMotorsGetsNoRumble() {
        #expect(ControllerHaptics(controller: GCController.withExtendedGamepad()) == nil)
    }
}
