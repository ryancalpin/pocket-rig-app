import CoreGraphics
import Foundation
import Testing
@testable import PocketRig

@Suite struct TrackpadInterpreterTests {
    @Test func oneFingerMovesThePointer() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: CGPoint(x: 100, y: 100), at: 0)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 110, y: 105)) == [.move(dx: 16, dy: 8)])
    }

    @Test func tinyMovesAddUp() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 0.5, y: 0)) == [])
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 1, y: 0)) == [.move(dx: 1, dy: 0)])
    }

    @Test func aQuickTapClicks() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: CGPoint(x: 50, y: 50), at: 0)
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.1) == [.button(.left, down: true), .button(.left, down: false)])
    }

    @Test func holdingDoesNotClick() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: CGPoint(x: 50, y: 50), at: 0)
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.5) == [])
    }

    @Test func movingDoesNotClick() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0)
        _ = pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 20, y: 0))
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.1) == [])
    }

    @Test func twoFingerTapRightClicks() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: CGPoint(x: 50, y: 50), at: 0)
        _ = pad.touchesBegan(fingers: 2, centroid: CGPoint(x: 60, y: 50), at: 0.02)
        #expect(pad.touchesEnded(remainingFingers: 1, at: 0.1) == [])
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.12) == [.button(.right, down: true), .button(.right, down: false)])
    }

    @Test func twoFingersScrollNaturally() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 2, centroid: CGPoint(x: 100, y: 100), at: 0)
        #expect(pad.touchesMoved(fingers: 2, centroid: CGPoint(x: 100, y: 110)) == [.scroll(30)])
        #expect(pad.touchesMoved(fingers: 2, centroid: CGPoint(x: 100, y: 100)) == [.scroll(-30)])
    }

    @Test func liftingOneOfTwoFingersDoesNotJumpThePointer() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 2, centroid: CGPoint(x: 100, y: 100), at: 0)
        _ = pad.touchesEnded(remainingFingers: 1, at: 0.3)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 200, y: 200)) == [])
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 210, y: 200)) == [])
    }

    @Test func cancelForgetsTheGesture() {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0)
        pad.cancel()
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.05) == [])
    }

    // MARK: Click-drag

    /// Tap at time 0 (lifts at 0.05), then touch again at `gap` seconds after the lift.
    private func tappedThenTouched(gap: TimeInterval) -> TrackpadInterpreter {
        var pad = TrackpadInterpreter()
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0)
        _ = pad.touchesEnded(remainingFingers: 0, at: 0.05)
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0.05 + gap)
        return pad
    }

    @Test func tapThenHoldAndDragPressesMovesAndReleases() {
        var pad = tappedThenTouched(gap: 0.1)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0)) == [.button(.left, down: true), .move(dx: 16, dy: 0)])
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 20, y: 0)) == [.move(dx: 16, dy: 0)])
        #expect(pad.touchesEnded(remainingFingers: 0, at: 1.0) == [.button(.left, down: false)])
    }

    @Test func aSlowSecondTouchJustMovesThePointer() {
        var pad = tappedThenTouched(gap: 0.5)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0)) == [.move(dx: 16, dy: 0)])
        #expect(pad.touchesEnded(remainingFingers: 0, at: 1.0) == [])
    }

    @Test func aSecondQuickTapStillClicks() {
        var pad = tappedThenTouched(gap: 0.1)
        #expect(pad.touchesEnded(remainingFingers: 0, at: 0.2) == [.button(.left, down: true), .button(.left, down: false)])
    }

    @Test func dragStartsOnlyAfterRealMovement() {
        var pad = tappedThenTouched(gap: 0.1)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 1, y: 0)) == [.move(dx: 1, dy: 0)])
        #expect(!pad.isDragging)
    }

    @Test func cancelReleasesTheButton() {
        var pad = tappedThenTouched(gap: 0.1)
        _ = pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0))
        #expect(pad.isDragging)
        #expect(pad.cancelAndRelease() == [.button(.left, down: false)])
        #expect(!pad.isDragging)
        #expect(pad.cancelAndRelease() == [])
        #expect(pad.touchesEnded(remainingFingers: 0, at: 2) == [])
    }

    @Test func cancelWithoutADragSendsNothing() {
        var pad = tappedThenTouched(gap: 0.1)
        #expect(pad.cancelAndRelease() == [])
    }

    @Test func aSecondFingerDuringADragReleasesTheButton() {
        var pad = tappedThenTouched(gap: 0.1)
        _ = pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0))
        #expect(pad.touchesBegan(fingers: 2, centroid: CGPoint(x: 10, y: 0), at: 0.6) == [.button(.left, down: false)])
        #expect(!pad.isDragging)
    }

    @Test func aDragDoesNotArmTheNextDrag() {
        var pad = tappedThenTouched(gap: 0.1)
        _ = pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0))
        _ = pad.touchesEnded(remainingFingers: 0, at: 0.4)
        _ = pad.touchesBegan(fingers: 1, centroid: .zero, at: 0.45)
        #expect(pad.touchesMoved(fingers: 1, centroid: CGPoint(x: 10, y: 0)) == [.move(dx: 16, dy: 0)])
    }
}
