import Foundation
import Testing
@testable import PocketRig

@Suite struct SpecialButtonModelTests {
    /// A button exactly as Phase 2 saved it.
    private static let phase2JSON = """
    [{"frame":{"height":0.1,"width":0.1,"x":0.5,"y":0.5},"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7",\
    "isHidden":false,"kind":"faceSouth","opacity":0.8}]
    """

    private static func combo(_ steps: [(GamepadButtons, Double)]) -> Macro {
        Macro(steps: steps.map { MacroStep(frame: MacroFrame(buttons: $0.0), seconds: $0.1) })
    }

    @Test func phase2ButtonsLoadAsNormalButtons() throws {
        let buttons = try JSONDecoder().decode([ControlButton].self, from: Data(Self.phase2JSON.utf8))
        #expect(buttons.count == 1)
        #expect(buttons[0].behavior == .normal)
        #expect(buttons[0].turboHz == ButtonBehavior.defaultTurboHz)
        #expect(buttons[0].macro == nil)
        #expect(buttons[0].opacity == 0.8)
    }

    @Test func phase2LayoutsStillLoad() {
        let layout = ControlLayout(name: "Old", pose: .upright, style: .xbox, buttons: [])
        layout.buttonsData = Data(Self.phase2JSON.utf8)
        #expect(layout.hasReadableButtons)
        #expect(layout.buttons.map(\.kind) == [.faceSouth])
    }

    @Test func plainButtonsSaveExactlyAsBefore() throws {
        let button = ControlButton(kind: .faceSouth, frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
        let data = try JSONEncoder().encode(button)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "frame", "opacity", "isHidden"])
    }

    @Test func specialSettingsRoundTrip() throws {
        let macro = Self.combo([(.a, 0.1), ([], 0.1), (.b, 0.2)])
        let button = ControlButton(kind: .faceNorth, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
                                   behavior: .macro, turboHz: 20, macro: macro)
        let back = try JSONDecoder().decode(ControlButton.self, from: JSONEncoder().encode(button))
        #expect(back == button)
        #expect(back.behavior == .macro)
        #expect(back.turboHz == 20)
        #expect(back.macro == macro)
    }

    @Test func unknownOrBrokenSettingsReadAsNormal() throws {
        let json = """
        {"frame":{"height":0.1,"width":0.1,"x":0.5,"y":0.5},"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7",\
        "isHidden":false,"kind":"faceSouth","opacity":1,"behavior":"teleport","turboHz":"fast","macro":42}
        """
        let button = try JSONDecoder().decode(ControlButton.self, from: Data(json.utf8))
        #expect(button.behavior == .normal)
        #expect(button.turboHz == ButtonBehavior.defaultTurboHz)
        #expect(button.macro == nil)
    }

    @Test func sticksAndTheDpadStayNormal() throws {
        let frame = NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2)
        #expect(ControlButton(kind: .leftStick, frame: frame, behavior: .turbo).behavior == .normal)
        #expect(ControlButton(kind: .dpad, frame: frame, behavior: .toggle).behavior == .normal)
        #expect(ControlButton(kind: .rightTrigger, frame: frame, behavior: .turbo).behavior == .turbo)
        let json = """
        {"frame":{"height":0.2,"width":0.2,"x":0,"y":0},"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7",\
        "kind":"dpad","behavior":"turbo"}
        """
        #expect(try JSONDecoder().decode(ControlButton.self, from: Data(json.utf8)).behavior == .normal)
    }

    @Test func aComboWithNothingRecordedActsNormal() {
        let frame = NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        #expect(ControlButton(kind: .faceNorth, frame: frame, behavior: .macro).activeBehavior == .normal)
        #expect(ControlButton(kind: .faceNorth, frame: frame, behavior: .turbo).activeBehavior == .turbo)
    }

    @Test func turboSpeedStaysInRange() {
        #expect(ButtonBehavior.clampedTurboHz(100) == 30)
        #expect(ButtonBehavior.clampedTurboHz(0) == 2)
        #expect(ButtonBehavior.clampedTurboHz(15) == 15)
        #expect(ButtonBehavior.turboTitle(15) == "15 presses a second")
        #expect(ButtonBehavior.turboOptions(including: 12) == [5, 10, 12, 15, 20])
        #expect(ButtonBehavior.turboOptions(including: 15) == [5, 10, 15, 20])
    }

    @Test func longCombosAreTrimmed() {
        let long = Self.combo(Array(repeating: (.a, 1.0), count: 100)).sanitized()
        #expect(long.steps.count == 15)
        #expect(approximately(long.duration, Macro.longestCombo))
        let many = Self.combo(Array(repeating: (.a, 0.05), count: 100)).sanitized()
        #expect(many.steps.count == Macro.maximumSteps)
    }

    @Test func brokenStepsAreRepaired() {
        let fixed = Self.combo([(.a, .nan), (.b, 0), (.x, 99)]).sanitized()
        #expect(fixed.steps.map(\.frame.pressed) == [.b, .x])
        #expect(fixed.steps[0].seconds == Macro.shortestStep)
        #expect(fixed.steps[1].seconds == Macro.longestStep)
    }

    @Test func combosPlayStepByStep() {
        let macro = Self.combo([(.a, 0.1), ([], 0.1), (.b, 0.2)])
        #expect(macro.frame(at: 0)?.pressed == .a)
        #expect(macro.frame(at: 0.15)?.isEmpty == true)
        #expect(macro.frame(at: 0.3)?.pressed == .b)
        #expect(macro.frame(at: 0.45) == nil)
        #expect(approximately(macro.nextBoundary(after: 0) ?? -1, 0.1))
        #expect(approximately(macro.nextBoundary(after: 0.25) ?? -1, 0.4))
        #expect(macro.nextBoundary(after: 0.4) == nil)
    }

    @Test func comboSummariesArePlain() {
        let us = Locale(identifier: "en_US")
        #expect(Self.combo([(.a, 0.1), ([], 0.1), (.b, 0.2)]).summary(locale: us) == "2 presses · 0.4 seconds")
        #expect(Self.combo([(.a, 1)]).summary(locale: us) == "1 press · 1 second")
        #expect(Self.combo([([.a, .b], 0.5)]).pressCount == 2)
    }

    @Test func gamepadStatesBecomeFrames() {
        var state = GamepadState()
        state.buttons = [.a, .up]
        state.leftTrigger = 0.9
        state.rightTrigger = 0.2
        state.leftStick = [1, 0]   // sticks aren't recorded
        #expect(MacroFrame(state) == MacroFrame(buttons: [.a, .up], leftTrigger: true))
        #expect(MacroFrame(GamepadState()).isEmpty)
    }

    @Test func sharedLayoutFilesKeepSpecialButtons() throws {
        let frame = NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let file = LayoutFile(name: "Turbo", pose: .upright, style: .xbox,
                              buttons: [ControlButton(kind: .faceSouth, frame: frame, behavior: .turbo, turboHz: 10)])
        let back = try LayoutFile.decode(file.encoded())
        #expect(back.buttons.first?.behavior == .turbo)
        #expect(back.buttons.first?.turboHz == 10)
    }
}

@Suite struct MacroFrameMaskingTests {
    @Test func initKeepsOnlyRealButtons() {
        let frame = MacroFrame(buttons: GamepadButtons(rawValue: Int32.max))
        #expect(frame.pressed == GamepadButtons.all)
    }

    @Test func decodingDropsHighBits() throws {
        let json = #"{"buttons": 2147483647, "leftTrigger": false, "rightTrigger": false}"#
        let frame = try JSONDecoder().decode(MacroFrame.self, from: Data(json.utf8))
        #expect(frame.pressed == GamepadButtons.all)
        #expect(frame.buttons & ~GamepadButtons.all.rawValue == 0)
    }
}
