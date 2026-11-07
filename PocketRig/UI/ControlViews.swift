import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The phone-vibration setting, for taps on on-screen buttons and keys.
    @Entry var hapticsStrength: HapticsStrength = .medium
}

/// One light-impact generator per control, created on first press and reused after.
@MainActor
final class Haptics {
    private var generator: UIImpactFeedbackGenerator?

    /// Warms the haptic engine so the first tap isn't laggy.
    func prepare() {
        let g = generator ?? UIImpactFeedbackGenerator(style: .light)
        generator = g
        g.prepare()
    }

    func tap(_ strength: HapticsStrength = .medium) {
        guard let intensity = strength.tapIntensity else { return }
        let g = generator ?? UIImpactFeedbackGenerator(style: .light)
        generator = g
        g.impactOccurred(intensity: intensity)
        g.prepare()
    }
}

/// Glyph sizes for on-screen controls. They grow with Dynamic Type, but never past a share of the control,
/// because the control's own size comes from the layout, not the text size.
enum ControlGlyph {
    /// Largest share of the control's shorter side a letter or symbol may take.
    static let maxGlyphShare: CGFloat = 0.5
    /// Largest share for the small corner badge (turbo, tap-to-hold, combo).
    static let maxBadgeShare: CGFloat = 0.3

    /// The text-style size scaled for Dynamic Type (`scaled`), capped by the control's shorter side.
    static func pointSize(scaled: CGFloat, control: CGSize, share: CGFloat = maxGlyphShare) -> CGFloat {
        let side = min(control.width, control.height)
        guard side > 0 else { return scaled }
        return min(scaled, side * share)
    }
}

/// A button that tracks its own finger, so several can be held at once.
struct HoldButton: View {
    let title: String?
    let symbol: String?
    let label: String
    var size = CGSize(width: 48, height: 48)
    var shape: AnyShape = AnyShape(Circle())
    /// A small mark in the corner (turbo, tap-to-hold, combo).
    var badge: String? = nil
    /// Drawn as pressed without a finger on it (a tap-to-hold button that is holding).
    var isLit = false
    let onChange: (Bool) -> Void

    /// True while a finger is down. SwiftUI resets it on end AND on cancel.
    @GestureState private var pressed = false
    @State private var haptics = Haptics()
    @Environment(\.hapticsStrength) private var hapticsStrength
    /// Body and headline are both 17 pt at the default text size; caption 2 is 11 pt.
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 17
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 11

    var body: some View {
        ZStack {
            shape.fill(pressed || isLit ? Color.white.opacity(0.45) : Color.white.opacity(0.18))
            shape.stroke(isLit ? Color.yellow : Color.white.opacity(0.5), lineWidth: isLit ? 2 : 1)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: ControlGlyph.pointSize(scaled: symbolSize, control: size), weight: .semibold))
            } else if let title {
                Text(title)
                    .font(.system(size: ControlGlyph.pointSize(scaled: titleSize, control: size), weight: .semibold))
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: ControlGlyph.pointSize(scaled: badgeSize, control: size,
                                                               share: ControlGlyph.maxBadgeShare), weight: .bold))
                    .padding(4)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(pressed ? 0.94 : 1)
        .contentShape(shape)
        .onAppear { haptics.prepare() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, state, _ in state = true }
        )
        .onChange(of: pressed) { _, isDown in
            if isDown { haptics.tap(hapticsStrength) }
            onChange(isDown)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // VoiceOver / automation activation: a quick press and release.
            onChange(true)
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                onChange(false)
            }
        }
    }
}

/// Circular stick: knob follows the finger, snaps back on release.
struct StickView: View {
    let label: String
    let diameter: CGFloat
    let resetToken: Int
    let onChange: (SIMD2<Float>) -> Void

    @State private var offset: CGSize = .zero
    /// True while a finger is down. SwiftUI resets it on end AND on cancel.
    @GestureState private var active = false
    @State private var haptics = Haptics()
    @Environment(\.hapticsStrength) private var hapticsStrength

    private var radius: CGFloat { diameter / 2 }
    private var knob: CGFloat { diameter * 0.45 }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.1))
            Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)
            Circle()
                .fill(Color.white.opacity(active ? 0.5 : 0.28))
                .frame(width: knob, height: knob)
                .offset(offset)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onAppear { haptics.prepare() }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($active) { _, state, _ in state = true }
                .onChanged { drag in
                    var dx = drag.location.x - radius
                    var dy = drag.location.y - radius
                    let length = (dx * dx + dy * dy).squareRoot()
                    if length > radius {
                        dx *= radius / length
                        dy *= radius / length
                    }
                    offset = CGSize(width: dx, height: dy)
                    // SwiftUI y grows downward; the gamepad's +y is up.
                    onChange([Float(dx / radius), Float(-dy / radius)])
                }
        )
        .onChange(of: active) { _, isActive in
            if isActive {
                haptics.tap(hapticsStrength)
            } else {
                release()
            }
        }
        .onChange(of: resetToken) { _, _ in release() }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    /// Safe to call repeatedly: the knob recentres and a neutral value is sent.
    private func release() {
        withAnimation(.snappy(duration: 0.12)) { offset = .zero }
        onChange(.zero)
    }
}

/// Four direction buttons in a 3 × 3 grid filling a `side`-point square.
struct DPadView: View {
    let side: CGFloat
    let onChange: (GamepadButtons, Bool) -> Void

    private var cell: CGFloat { side / 3 }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                gap
                arrow("chevron.up", "D-pad up", .up)
                gap
            }
            GridRow {
                arrow("chevron.left", "D-pad left", .left)
                gap
                arrow("chevron.right", "D-pad right", .right)
            }
            GridRow {
                gap
                arrow("chevron.down", "D-pad down", .down)
                gap
            }
        }
        .frame(width: side, height: side)
    }

    private var gap: some View {
        Color.clear.frame(width: cell, height: cell)
    }

    private func arrow(_ symbol: String, _ label: String, _ flag: GamepadButtons) -> some View {
        HoldButton(title: nil, symbol: symbol, label: label, size: CGSize(width: cell, height: cell),
                   shape: AnyShape(RoundedRectangle(cornerRadius: 8))) { onChange(flag, $0) }
    }
}
