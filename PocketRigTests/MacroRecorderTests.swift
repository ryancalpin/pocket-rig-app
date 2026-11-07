import CoreGraphics
import Foundation
import Testing
@testable import PocketRig

@Suite struct MacroRecorderTests {
    private let a = MacroFrame(buttons: .a), b = MacroFrame(buttons: .b), idle = MacroFrame()

    @Test func waitingBeforeTheFirstPressIsSkipped() {
        var r = MacroRecorder()
        r.record(idle, at: 0)
        r.record(a, at: 3)
        r.record(idle, at: 3.2)
        let m = r.finished(at: 5)
        #expect(m.steps.map(\.frame) == [a])   // trailing wait dropped too
        #expect(approximately(m.duration, 0.2))
    }

    @Test func timingIsKept() {
        var r = MacroRecorder()
        r.record(a, at: 0)
        r.record(idle, at: 0.1)
        r.record(b, at: 0.3)
        r.record(idle, at: 0.5)
        let m = r.finished(at: 1)
        #expect(m.steps.map(\.frame) == [a, idle, b])
        #expect(approximately(m.steps[0].seconds, 0.1))
        #expect(approximately(m.steps[1].seconds, 0.2))
        #expect(approximately(m.steps[2].seconds, 0.2))
    }

    @Test func aButtonStillHeldAtTheEndIsKept() {
        var r = MacroRecorder()
        r.record(a, at: 0)
        let m = r.finished(at: 0.4)
        #expect(m.steps.map(\.frame) == [a])
        #expect(approximately(m.steps[0].seconds, 0.4))
    }

    @Test func theSameStateTwiceIsOneStep() {
        var r = MacroRecorder()
        r.record(a, at: 0)
        r.record(a, at: 0.1)
        r.record(idle, at: 0.2)
        #expect(r.finished(at: 0.3).steps.count == 1)
    }

    @Test func veryShortAndVeryLongStepsStaySensible() {
        var r = MacroRecorder()
        r.record(a, at: 0)
        r.record(idle, at: 0.001)
        r.record(b, at: 20)
        r.record(idle, at: 20.1)
        let seconds = r.finished(at: 21).steps.map(\.seconds)
        #expect(seconds.count == 3)
        #expect(seconds[0] == Macro.shortestStep)
        #expect(seconds[1] == Macro.longestStep)
        #expect(approximately(seconds[2], 0.1))
    }

    @Test func itStopsAtTheLimit() {
        var r = MacroRecorder()
        for i in 0..<200 { r.record(i.isMultiple(of: 2) ? a : idle, at: Double(i) * 0.05) }
        #expect(r.isFull)
        let m = r.finished(at: 10)
        #expect(m.steps.count <= Macro.maximumSteps)
        #expect(m.duration < 4)   // the 10 s of waiting at the end isn't part of it
    }

    @Test func theLastReleaseIsKeptAtTheLimit() {
        var r = MacroRecorder()
        var t = 0.0
        var i = 0
        while !r.isFull {
            r.record(i.isMultiple(of: 2) ? a : b, at: t)   // always a press, so one is still held
            t += 0.05
            i += 1
        }
        let release = t
        r.record(idle, at: release + 0.3)                  // let go after 0.3 s
        r.record(a, at: release + 0.4)                     // too late: no new steps
        let m = r.finished(at: release + 8)                // Save tapped much later
        #expect(m.steps.count <= Macro.maximumSteps)
        #expect(approximately(m.steps.last?.seconds ?? 0, 0.3 + 0.05))
        #expect(m.steps.last?.frame.isEmpty == false)
    }

    @Test func pressesAreCounted() {
        var r = MacroRecorder()
        #expect(!r.hasPresses)
        r.record(a, at: 0)
        #expect(r.hasPresses)
        #expect(r.pressCount == 1)
        r.record(MacroFrame(buttons: [.a, .b]), at: 0.1)
        #expect(r.pressCount == 2)
    }

    @Test func startingOverForgetsEverything() {
        var r = MacroRecorder()
        r.record(a, at: 0)
        r.reset()
        #expect(!r.hasPresses)
        #expect(r.finished(at: 1).isEmpty)
    }

    @Test func thePracticePadHasOneOfEachButtonAndNoSticks() {
        var layout = DefaultLayouts.buttons(for: .upright)
        layout += layout.map { var copy = $0; copy.id = UUID(); copy.behavior = .turbo; return copy }
        let pad = MacroRecorder.recordingPad(from: layout)
        let kinds = pad.map(\.kind)
        #expect(Set(kinds).count == kinds.count)
        #expect(!kinds.contains(.leftStick))
        #expect(!kinds.contains(.rightStick))
        #expect(kinds.contains(.dpad))
        #expect(kinds.contains(.faceSouth))
        #expect(pad.allSatisfy { $0.behavior == .normal && $0.macro == nil })
    }

    @Test @MainActor func thePracticePadFeedsTheRecorder() {
        let clock = FakeClock()
        let session = MacroRecordingSession(now: { clock.now })
        session.input.update { $0.buttons.insert(.a) }
        clock.now += 0.2
        session.input.update { $0.buttons.remove(.a) }
        clock.now += 0.1
        session.input.update { $0.buttons.insert(.b) }
        clock.now += 0.2
        session.input.update { $0.buttons.remove(.b) }
        let macro = session.finished()
        #expect(macro.steps.map(\.frame) == [a, idle, b])
        #expect(approximately(macro.duration, 0.5))
        session.startOver()
        #expect(!session.recorder.hasPresses)
    }
}

@Suite struct LayoutCopyTests {
    private let size = CGSize(width: 400, height: 300)

    @Test func aCopySitsBesideTheOriginalAsAPlainButton() {
        let original = ControlButton(kind: .faceSouth, frame: NormalizedRect(x: 0.1, y: 0.5, width: 0.1, height: 0.1),
                                     opacity: 0.6, behavior: .turbo)
        let copy = LayoutEditing.copy(of: original, in: size)
        #expect(copy.id != original.id)
        #expect(copy.kind == .faceSouth)
        #expect(copy.behavior == .normal)
        #expect(copy.opacity == 0.6)
        #expect(copy.frame.y == original.frame.y)
        #expect(copy.frame.width == original.frame.width)
        #expect(copy.frame.x > original.frame.x + original.frame.width)
    }

    @Test func nearTheRightEdgeTheCopyGoesLeft() {
        let original = ControlButton(kind: .faceEast, frame: NormalizedRect(x: 0.85, y: 0.5, width: 0.1, height: 0.1))
        let copy = LayoutEditing.copy(of: original, in: size)
        #expect(copy.frame.x + copy.frame.width < original.frame.x)
    }

    @Test func copiesStopAtTheLayoutLimit() {
        let button = ControlButton(kind: .faceSouth, frame: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
        #expect(LayoutEditing.canAddCopy(to: Array(repeating: button, count: LayoutFile.maximumButtons - 1)))
        #expect(!LayoutEditing.canAddCopy(to: Array(repeating: button, count: LayoutFile.maximumButtons)))
    }

    @Test func onlyExtraCopiesCanBeRemoved() {
        let frame = NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let first = ControlButton(kind: .faceSouth, frame: frame)
        let other = ControlButton(kind: .faceEast, frame: frame)
        #expect(!LayoutEditing.canRemove(first, from: [first, other]))
        let second = LayoutEditing.copy(of: first, in: size)
        #expect(LayoutEditing.canRemove(first, from: [first, other, second]))
        #expect(LayoutEditing.canRemove(second, from: [first, other, second]))
    }
}
