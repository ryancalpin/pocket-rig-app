import CoreGraphics
import Foundation

/// A control's final spot on screen.
struct PlacedControl: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ControlKind
    let rect: CGRect
    let opacity: Double
}

/// Turns a layout into on-screen rectangles: round controls stay round, nothing gets too small to hit,
/// neighbours keep a finger-width gap, and nothing sits flush against the edge of the deck.
enum ControlPlacement {
    /// The smallest gap left between two controls, so a thumb on one doesn't also brush the other.
    static let minimumGap: CGFloat = 8
    /// How far controls stay from the deck's edges.
    static let edgeInset: CGFloat = 8

    /// A d-pad needs three 44 pt cells; a stick needs room for the thumb to travel.
    static func minimumSide(for kind: ControlKind) -> CGFloat {
        switch kind {
        case .dpad: 132
        case .leftStick, .rightStick: 96
        default: 44
        }
    }

    static func place(_ button: ControlButton, in size: CGSize) -> CGRect {
        var rect = button.frame.rect(in: size)
        if button.kind.keepsAspect {
            let side = min(rect.width, rect.height)
            rect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        }
        let minSide = minimumSide(for: button.kind)
        if rect.width < minSide || rect.height < minSide {
            let w = max(rect.width, minSide), h = max(rect.height, minSide)
            rect = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        return clamped(rect, in: size)
    }

    static func visible(_ buttons: [ControlButton], in size: CGSize) -> [PlacedControl] {
        let shown = DefaultLayouts.adapted(buttons, to: size).filter { !$0.isHidden }
        let rects = separated(shown.map { place($0, in: size) }, in: size)
        return zip(shown, rects).map { button, rect in
            PlacedControl(id: button.id, kind: button.kind, rect: rect,
                          opacity: min(max(button.opacity, ControlButton.minimumOpacity), 1))
        }
    }

    /// Growing small controls to tap size can push neighbours into each other on small decks.
    /// Nudges each pair closer than `minimumGap` apart along the axis that needs the least movement,
    /// keeping everything inside the deck's edge inset and never shrinking anything. Same input, same output.
    static func separated(_ input: [CGRect], in size: CGSize, iterations: Int = 200) -> [CGRect] {
        var rects = input
        for _ in 0..<iterations {
            var moved = false
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let a = rects[i], b = rects[j]
                    // How far each axis is from having the minimum gap; both positive means too close.
                    let ox = min(a.maxX, b.maxX) - max(a.minX, b.minX) + minimumGap
                    let oy = min(a.maxY, b.maxY) - max(a.minY, b.minY) + minimumGap
                    guard ox > 0.01, oy > 0.01 else { continue }
                    moved = true
                    var da = CGVector.zero
                    if ox <= oy {
                        let s: CGFloat = a.midX <= b.midX ? -1 : 1
                        da.dx = s * ox / 2
                    } else {
                        let s: CGFloat = a.midY <= b.midY ? -1 : 1
                        da.dy = s * oy / 2
                    }
                    rects[i] = clamped(a.offsetBy(dx: da.dx, dy: da.dy), in: size)
                    rects[j] = clamped(b.offsetBy(dx: -da.dx, dy: -da.dy), in: size)
                }
            }
            if !moved { break }
        }
        return rects
    }

    /// Keeps a rect `edgeInset` inside the area. A rect too big for the inset is centred instead
    /// (and pinned to the edge if it is bigger than the whole area).
    private static func clamped(_ rect: CGRect, in size: CGSize) -> CGRect {
        func axis(_ origin: CGFloat, _ length: CGFloat, _ total: CGFloat) -> CGFloat {
            let low = edgeInset, high = total - edgeInset - length
            if high >= low { return min(max(origin, low), high) }
            return max((total - length) / 2, 0)
        }
        var r = rect
        r.origin.x = axis(r.minX, r.width, size.width)
        r.origin.y = axis(r.minY, r.height, size.height)
        return r
    }
}
