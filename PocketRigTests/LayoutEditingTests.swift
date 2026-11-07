import CoreGraphics
import Testing
@testable import PocketRig

@Suite struct LayoutEditingTests {
    private let canvas = CGSize(width: 500, height: 500)

    private func button(_ kind: ControlKind, x: Double, y: Double, side: Double) -> ControlButton {
        ControlButton(kind: kind, frame: NormalizedRect(x: x, y: y, width: side, height: side))
    }

    @Test func dragMovesByTheFingersDistance() {
        let moved = LayoutEditing.move(button(.faceSouth, x: 0.1, y: 0.1, side: 0.2), by: CGSize(width: 50, height: 100), in: canvas)
        #expect(abs(moved.frame.x - 0.2) < 0.0001)
        #expect(abs(moved.frame.y - 0.3) < 0.0001)
    }

    @Test func dragStopsAtTheEdge() {
        let moved = LayoutEditing.move(button(.faceSouth, x: 0.7, y: 0, side: 0.2), by: CGSize(width: 500, height: -50), in: canvas)
        #expect(abs(moved.frame.x - 0.8) < 0.0001)
        #expect(moved.frame.y == 0)
    }

    @Test func roundControlsResizeEvenly() {
        let resized = LayoutEditing.resize(button(.leftStick, x: 0, y: 0, side: 0.2), by: CGSize(width: 40, height: 10), in: canvas)
        #expect(abs(resized.frame.width - 0.28) < 0.0001)
        #expect(abs(resized.frame.height - 0.28) < 0.0001)
    }

    @Test func resizingNeverGoesBelowATapTarget() {
        let resized = LayoutEditing.resize(button(.faceSouth, x: 0, y: 0, side: 0.2), by: CGSize(width: -90, height: -90), in: canvas)
        #expect(abs(resized.frame.width - 44.0 / 500) < 0.0001)
    }

    @Test func resizingStopsAtTheEdge() {
        var bumper = button(.leftBumper, x: 0.8, y: 0, side: 0.1)
        bumper.frame.height = 0.1
        let resized = LayoutEditing.resize(bumper, by: CGSize(width: 200, height: 0), in: canvas)
        #expect(abs(resized.frame.width - 0.2) < 0.0001)
    }

    @Test func savingTheFallbackDeletesTheSavedCopy() {
        let fallback = LayoutStore.builtIn(pose: .laptop)
        #expect(LayoutEditing.saveAction(buttons: fallback.buttons, style: .xbox, hasSaved: true, fallback: fallback) == .deleteSaved)
        #expect(LayoutEditing.saveAction(buttons: fallback.buttons, style: .xbox, hasSaved: false, fallback: fallback) == .nothing)
    }

    @Test func anyChangeIsSaved() {
        let fallback = LayoutStore.builtIn(pose: .laptop)
        var buttons = fallback.buttons
        buttons[2].opacity = 0.5
        #expect(LayoutEditing.saveAction(buttons: buttons, style: .xbox, hasSaved: false, fallback: fallback) == .save)
        #expect(LayoutEditing.saveAction(buttons: fallback.buttons, style: .nintendo, hasSaved: false, fallback: fallback) == .save)
    }

    @Test func theMinimumIsMeasuredInRealDeckPoints() {
        // A canvas drawn at half size: 44 real points is 22 canvas points.
        let resized = LayoutEditing.resize(button(.faceSouth, x: 0, y: 0, side: 0.2), by: CGSize(width: -90, height: -90),
                                           in: canvas, scale: 0.5)
        #expect(abs(resized.frame.width - 22.0 / 500) < 0.0001)
    }

    @Test func aControlTooCloseToTheEdgeNeverLeavesTheCanvas() {
        let near = button(.faceSouth, x: 0.95, y: 0, side: 0.05)   // 25 pt of room, minimum 44
        let resized = LayoutEditing.resize(near, by: CGSize(width: 30, height: 30), in: canvas)
        #expect(resized.frame.x + resized.frame.width <= 1.0001)
        #expect(resized.frame.width == resized.frame.height)
    }
}
