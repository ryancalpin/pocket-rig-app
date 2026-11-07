import CoreGraphics
import Foundation

/// The editor's rules, kept out of the view so they can be tested.
enum LayoutEditing {
    /// Moves by the finger's travel (points on a canvas of `size`), staying on the canvas.
    static func move(_ button: ControlButton, by translation: CGSize, in size: CGSize) -> ControlButton {
        guard size.width > 0, size.height > 0 else { return button }
        var moved = button
        moved.frame.x += Double(translation.width / size.width)
        moved.frame.y += Double(translation.height / size.height)
        moved.frame = moved.frame.clamped(in: size, minimumPoints: 0)
        return moved
    }

    /// Grows or shrinks from the bottom-right corner. Round controls stay round; nothing goes below its
    /// minimum tap size or past the canvas edge. `scale` is canvas points per real deck point (a canvas
    /// drawn at half size has 0.5), so the minimum is measured in real points, not canvas points.
    static func resize(_ button: ControlButton, by translation: CGSize, in size: CGSize,
                       scale: CGFloat = 1) -> ControlButton {
        guard size.width > 0, size.height > 0 else { return button }
        let rect = button.frame.rect(in: size)
        let minSide = ControlPlacement.minimumSide(for: button.kind) * (scale > 0 ? scale : 1)
        let maxW = size.width - rect.minX, maxH = size.height - rect.minY
        var w = rect.width + translation.width, h = rect.height + translation.height
        if button.kind.keepsAspect {
            let side = clampSide(max(w, h), minimum: minSide, maximum: min(maxW, maxH))
            w = side
            h = side
        } else {
            w = clampSide(w, minimum: minSide, maximum: maxW)
            h = clampSide(h, minimum: minSide, maximum: maxH)
        }
        var resized = button
        resized.frame = NormalizedRect(CGRect(x: rect.minX, y: rect.minY, width: w, height: h), in: size)
        return resized
    }

    /// Keeps `value` within the limits. If there is less room than the minimum, the room wins
    /// (the control can't be pushed off the canvas).
    private static func clampSide(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        max(0, min(max(value, minimum), maximum))
    }

    static func canAddCopy(to buttons: [ControlButton]) -> Bool {
        buttons.count < LayoutFile.maximumButtons
    }

    /// Only extra copies can be removed; the original of each control can be hidden instead.
    static func canRemove(_ button: ControlButton, from buttons: [ControlButton]) -> Bool {
        buttons.count(where: { $0.kind == button.kind }) > 1
    }

    /// A plain copy of `button` beside it: to the right if there's room, otherwise to the left.
    /// `size` is the real deck size, so the gap is `ControlPlacement.minimumGap` points.
    static func copy(of button: ControlButton, in size: CGSize) -> ControlButton {
        var copy = button
        copy.id = UUID()
        copy.behavior = .normal
        copy.turboHz = ButtonBehavior.defaultTurboHz
        copy.macro = nil
        let width = button.frame.width
        let gap = size.width > 0 ? Double(ControlPlacement.minimumGap / size.width) : 0.02
        if button.frame.x + width + gap + width <= 1 {
            copy.frame.x = button.frame.x + width + gap
        } else {
            copy.frame.x = max(0, button.frame.x - width - gap)
        }
        return copy
    }

    enum SaveAction: Equatable, Sendable { case save, deleteSaved, nothing }

    /// A layout identical to what it would fall back to isn't stored; any saved copy is removed instead.
    static func saveAction(buttons: [ControlButton], style: ControllerStyle, hasSaved: Bool,
                           fallback: ResolvedLayout) -> SaveAction {
        if buttons == fallback.buttons, style == fallback.style { return hasSaved ? .deleteSaved : .nothing }
        return .save
    }
}
