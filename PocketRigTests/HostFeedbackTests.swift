import CMoonlight
import GameController
import Testing
@testable import PocketRig

/// Records arrivals with their capability flags.
final class CapabilityRecordingSender: ControllerEventSending, @unchecked Sendable {
    private(set) var arrivals: [(type: UInt8, capabilities: UInt16)] = []
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) {}
    func arrive(controller: Int16, activeMask: Int16, type: UInt8, capabilities: UInt16) {
        arrivals.append((type, capabilities))
    }
}

@Suite @MainActor struct HostFeedbackTests {
    @Test func flagsMatchMoonlight() {
        #expect(ControllerCapabilities.flags(rumble: false, triggerRumble: false, motion: false)
                == UInt16(LI_CCAP_ANALOG_TRIGGERS))
        #expect(ControllerCapabilities.flags(rumble: true, triggerRumble: true, motion: true)
                == UInt16(LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE | LI_CCAP_TRIGGER_RUMBLE
                          | LI_CCAP_ACCEL | LI_CCAP_GYRO))
    }

    @Test func theTouchPadAsksForRumbleButNotMotion() {
        let flags = ControllerCapabilities.touchPad
        #expect(flags & UInt16(LI_CCAP_RUMBLE) != 0)
        #expect(flags & UInt16(LI_CCAP_TRIGGER_RUMBLE) != 0)
        #expect(flags & UInt16(LI_CCAP_GYRO) == 0)
        #expect(flags & UInt16(LI_CCAP_ACCEL) == 0)
    }

    @Test func theTouchPadArrivesAsAnXboxPadThatRumbles() {
        let sender = CapabilityRecordingSender()
        GamepadInput(sender: sender).announceArrival()
        #expect(sender.arrivals.count == 1)
        #expect(sender.arrivals.first?.type == UInt8(LI_CTYPE_XBOX))
        #expect(sender.arrivals.first?.capabilities == ControllerCapabilities.touchPad)
    }

    @Test func sendersWithoutCapabilitiesStillHearArrivals() {
        let sender = ArrivalRecordingSender()
        GamepadInput(sender: sender).announceArrival()
        #expect(sender.arrivals.count == 1)
        #expect(sender.arrivals.first?.type == UInt8(LI_CTYPE_XBOX))
    }

    @Test func aPadWithoutMotorsOrSensorsOnlyHasAnalogTriggers() {
        let pad = GCController.withExtendedGamepad()
        #expect(PhysicalControllerMonitor.capabilities(for: pad) == UInt16(LI_CCAP_ANALOG_TRIGGERS))
    }
}
