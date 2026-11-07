import Testing
import CMoonlight
import GameController
@testable import PocketRig

final class RecordingSender: ControllerEventSending, @unchecked Sendable {
    private(set) var sent: [GamepadState] = []
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) { sent.append(state) }
}

final class ArrivalRecordingSender: ControllerEventSending, @unchecked Sendable {
    private(set) var arrivals: [(controller: Int16, mask: Int16, type: UInt8)] = []
    func send(_ state: GamepadState, controller: Int16, activeMask: Int16) {}
    func arrive(controller: Int16, activeMask: Int16, type: UInt8) {
        arrivals.append((controller, activeMask, type))
    }
}

@Suite struct GamepadStateTests {
    @Test func buttonFlagsMatchMoonlight() {
        #expect(GamepadButtons.a.rawValue == Int32(A_FLAG))
        #expect(GamepadButtons.start.rawValue == Int32(PLAY_FLAG))
        #expect(GamepadButtons.guide.rawValue == Int32(SPECIAL_FLAG))
        #expect(GamepadButtons.leftBumper.rawValue == Int32(LB_FLAG))
    }

    @Test func wireValuesScaleAndClamp() {
        var s = GamepadState()
        s.buttons = [.a, .rightBumper]
        s.leftTrigger = 1; s.rightTrigger = 0.5
        s.leftStick = [1, -1]; s.rightStick = [2, 0]
        let w = s.wire
        #expect(w.buttons == Int32(A_FLAG | RB_FLAG))
        #expect(w.lt == 255 && w.rt == 127)
        #expect(w.lx == 32767 && w.ly == -32767)
        #expect(w.rx == 32767 && w.ry == 0)
    }

    @Test @MainActor func touchUpdatesSendImmediately() {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender)
        input.update { $0.buttons.insert(.b) }
        input.update { $0.buttons.remove(.b) }
        #expect(sender.sent.map(\.buttons) == [[.b], []])
    }

    @Test @MainActor func unchangedUpdateIsNotSent() {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender)
        input.update { $0.buttons.insert(.b) }
        input.update { $0.buttons.insert(.b) }
        #expect(sender.sent.count == 1)
    }

    @Test @MainActor func releaseAllSendsOneNeutralStateThenNothing() {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender)
        input.update { $0.buttons.insert(.b) }
        input.update { $0.leftStick = [0.5, -0.5] }
        #expect(sender.sent.count == 2)
        input.releaseAll()
        #expect(sender.sent.count == 3)
        #expect(sender.sent.last == GamepadState())
        input.releaseAll()
        #expect(sender.sent.count == 3)
    }

    @Test @MainActor func subQuantumJitterIsNotResent() {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender)
        input.update { $0.leftStick = [0.5, 0] }
        input.update { $0.leftStick = [0.5 + 1e-7, 0] }
        #expect(sender.sent.count == 1)
    }

    @Test @MainActor func arrivalSentOnceWhenAnnounced() {
        let sender = ArrivalRecordingSender()
        let input = GamepadInput(sender: sender)
        input.announceArrival()
        #expect(sender.arrivals.count == 1)
        #expect(sender.arrivals[0].controller == 0 && sender.arrivals[0].mask == 1)
    }

    @Test @MainActor func physicalGamepadMapsToState() {
        let controller = GCController.withExtendedGamepad()
        let pad = controller.extendedGamepad!
        pad.buttonA.setValue(1)
        pad.leftShoulder.setValue(1)
        pad.rightTrigger.setValue(1)
        pad.leftThumbstick.xAxis.setValue(0.5)
        pad.leftThumbstick.yAxis.setValue(1)
        pad.buttonMenu.setValue(1)
        let s = PhysicalControllerMonitor.state(from: pad)
        #expect(s.buttons.contains(.a))
        #expect(s.buttons.contains(.leftBumper))
        #expect(s.buttons.contains(.start))
        #expect(!s.buttons.contains(.b))
        #expect(s.rightTrigger == 1)
        #expect(s.leftStick.x == 0.5 && s.leftStick.y == 1)
    }
}
