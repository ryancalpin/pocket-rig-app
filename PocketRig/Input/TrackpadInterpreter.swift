import CoreGraphics
import Foundation

/// Turns touches on the trackpad tab into mouse events, like a laptop trackpad: one finger moves, a
/// quick tap clicks, a two-finger tap right-clicks, two fingers scroll. Tap, then touch again within a
/// moment and drag: the left button stays down while you drag (select text, move windows).
struct TrackpadInterpreter: Sendable {
    static let sensitivity: CGFloat = 1.6
    /// High-res wheel units per point of finger travel (120 units = one notch).
    static let scrollUnitsPerPoint: CGFloat = 3
    static let tapMaxDuration: TimeInterval = 0.25
    static let tapMaxTravel: CGFloat = 10
    /// A touch that lands this soon after a tap can become a click-drag.
    static let dragWindow: TimeInterval = 0.3
    /// How far the second touch must travel before the button goes down.
    static let dragStartTravel: CGFloat = 4

    private var maxFingers = 0
    private var startTime: TimeInterval = 0
    private var lastCentroid: CGPoint?
    private var travel: CGFloat = 0
    /// Sub-pixel movement carried to the next event, so slow drags still move.
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder: CGFloat = 0
    /// When the last one-finger tap lifted, if it could still start a click-drag.
    private var lastTapEnd: TimeInterval?
    /// This touch landed soon enough after a tap that moving it starts a drag.
    private var dragArmed = false
    /// The left button is held down right now.
    private(set) var isDragging = false

    mutating func touchesBegan(fingers: Int, centroid: CGPoint, at time: TimeInterval) -> [PointerEvent] {
        var events: [PointerEvent] = []
        if maxFingers == 0 {
            dragArmed = fingers == 1 && lastTapEnd.map { time - $0 <= Self.dragWindow } == true
            lastTapEnd = nil
            startTime = time
            travel = 0
            moveRemainder = .zero
            scrollRemainder = 0
        }
        maxFingers = max(maxFingers, fingers)
        if fingers >= 2 {
            dragArmed = false
            events += releaseDrag()
        }
        // A new finger shifts the centre point; that isn't movement.
        lastCentroid = centroid
        return events
    }

    mutating func touchesMoved(fingers: Int, centroid: CGPoint) -> [PointerEvent] {
        guard maxFingers > 0 else { return [] }
        guard let last = lastCentroid else {
            lastCentroid = centroid
            return []
        }
        lastCentroid = centroid
        let dx = centroid.x - last.x, dy = centroid.y - last.y
        travel += (dx * dx + dy * dy).squareRoot()
        if fingers >= 2 {
            // Natural scrolling: fingers move down, the page follows (wheel up).
            scrollRemainder += dy * Self.scrollUnitsPerPoint
            let amount = scrollRemainder.rounded(.towardZero)
            guard amount != 0 else { return [] }
            scrollRemainder -= amount
            return [.scroll(Int16(clamping: Int(amount)))]
        }
        // One finger left over from a two-finger gesture: ignore it.
        guard maxFingers == 1 else { return [] }
        var events: [PointerEvent] = []
        if dragArmed, !isDragging, travel > Self.dragStartTravel {
            isDragging = true
            events.append(.button(.left, down: true))
        }
        moveRemainder.x += dx * Self.sensitivity
        moveRemainder.y += dy * Self.sensitivity
        let mx = moveRemainder.x.rounded(.towardZero), my = moveRemainder.y.rounded(.towardZero)
        guard mx != 0 || my != 0 else { return events }
        moveRemainder.x -= mx
        moveRemainder.y -= my
        events.append(.move(dx: Int16(clamping: Int(mx)), dy: Int16(clamping: Int(my))))
        return events
    }

    mutating func touchesEnded(remainingFingers: Int, at time: TimeInterval) -> [PointerEvent] {
        guard maxFingers > 0 else { return [] }
        guard remainingFingers == 0 else {
            lastCentroid = nil
            return []
        }
        let release = releaseDrag()
        let isTap = time - startTime <= Self.tapMaxDuration && travel <= Self.tapMaxTravel
        let fingers = maxFingers
        cancel()
        guard release.isEmpty else { return release }
        guard isTap else { return [] }
        if fingers == 1 { lastTapEnd = time }
        let button: MouseButton = fingers >= 2 ? .right : .left
        return [.button(button, down: true), .button(button, down: false)]
    }

    /// Forgets the gesture. If the button is down, use `cancelAndRelease()` so it gets let go.
    mutating func cancel() {
        maxFingers = 0
        lastCentroid = nil
        travel = 0
        moveRemainder = .zero
        scrollRemainder = 0
        dragArmed = false
        lastTapEnd = nil
        isDragging = false
    }

    /// Forgets the gesture and lets go of the left button if a drag had it down.
    mutating func cancelAndRelease() -> [PointerEvent] {
        let release = releaseDrag()
        cancel()
        return release
    }

    private mutating func releaseDrag() -> [PointerEvent] {
        guard isDragging else { return [] }
        isDragging = false
        return [.button(.left, down: false)]
    }
}
