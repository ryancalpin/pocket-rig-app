import SwiftUI

/// The on-screen gamepad, drawn from a button layout.
struct TouchGamepadView: View {
    let input: GamepadInput
    let buttons: [ControlButton]
    let style: ControllerStyle
    /// False when the pad floats over the video or sits in the deck, so nothing behind it is dimmed.
    let showsBackdrop: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(input: GamepadInput, buttons: [ControlButton] = DefaultLayouts.buttons(for: .upright),
         style: ControllerStyle = .xbox, showsBackdrop: Bool = true) {
        self.input = input
        self.buttons = buttons
        self.style = style
        self.showsBackdrop = showsBackdrop
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if showsBackdrop { Color.black.opacity(0.85) }
                ForEach(ControlPlacement.visible(buttons, in: geo.size)) { placed in
                    control(placed)
                        .opacity(placed.opacity)
                        .position(x: placed.rect.midX, y: placed.rect.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onDisappear { input.releaseAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { input.releaseAll() }
        }
        // A new layout or style can move a control out from under a finger; let go of everything.
        .onChange(of: buttons) { input.releaseAll() }
        .onChange(of: style) { input.releaseAll() }
    }

    @ViewBuilder
    private func control(_ placed: PlacedControl) -> some View {
        let face = style.face(for: placed.kind)
        let size = placed.rect.size
        let special = buttons.first { $0.id == placed.id && $0.activeBehavior != .normal }
        switch style.input(for: placed.kind) {
        case .button(let flag):
            if let special {
                specialButton(special, face: face, size: size, target: .button(flag))
            } else {
                HoldButton(title: face.title, symbol: face.symbol, label: face.name, size: size,
                           shape: shape(for: placed.kind)) { set(flag, $0) }
            }
        case .trigger(let left):
            if let special {
                specialButton(special, face: face, size: size, target: .trigger(left: left))
            } else {
                HoldButton(title: face.title, symbol: face.symbol, label: face.name, size: size,
                           shape: shape(for: placed.kind)) { down in
                    input.update {
                        if left { $0.leftTrigger = down ? 1 : 0 } else { $0.rightTrigger = down ? 1 : 0 }
                    }
                }
            }
        case .stick(let left):
            StickView(label: face.name, diameter: min(size.width, size.height), resetToken: input.resetToken) { v in
                input.update { if left { $0.leftStick = v } else { $0.rightStick = v } }
            }
        case .dpad:
            DPadView(side: min(size.width, size.height)) { flag, down in set(flag, down) }
        }
    }

    /// Turbo, tap-to-hold and combo buttons: their timing lives in `GamepadInput`, not in the view.
    private func specialButton(_ button: ControlButton, face: ControlFace, size: CGSize,
                               target: PressTarget) -> some View {
        let behavior = button.activeBehavior
        let binding = SpecialBinding(target: target, behavior: behavior, turboHz: button.turboHz, macro: button.macro)
        let isHolding = input.latchedIDs.contains(button.id)
        let pad = HoldButton(title: face.title, symbol: face.symbol, label: "\(face.name), \(behavior.title)",
                             size: size, shape: shape(for: button.kind), badge: behavior.badgeSymbol,
                             isLit: isHolding) { down in
            input.special(button.id, binding, down: down)
        }
        .accessibilityHint(behavior.explanation)
        return Group {
            if behavior == .toggle {
                pad.accessibilityValue(isHolding ? "Holding" : "Not holding")
            } else {
                pad
            }
        }
    }

    private func shape(for kind: ControlKind) -> AnyShape {
        kind.keepsAspect ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12))
    }

    private func set(_ flag: GamepadButtons, _ down: Bool) {
        input.update { if down { $0.buttons.insert(flag) } else { $0.buttons.remove(flag) } }
    }
}

#Preview {
    TouchGamepadView(input: GamepadInput(sender: NoOpControllerSender()))
}
