import SwiftUI
import UIKit

/// Deck tab: a laptop-style trackpad, a row of keys, and the phone keyboard for typing.
struct TrackpadTab: View {
    let pointer: any PointerEventSending
    let isLive: Bool
    @State private var typing = false
    @State private var keyTaps = 0
    @Environment(\.hapticsStrength) private var hapticsStrength

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.2), lineWidth: 1))
                Text("Drag to move. Tap to click. Two-finger tap to right-click. Drag two fingers to scroll.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .allowsHitTesting(false)
                TrackpadSurface(isLive: isLive, strength: hapticsStrength, onTouch: { typing = false }) { events in
                    for event in events { pointer.send(event) }
                }
                .accessibilityLabel("Trackpad")
                .accessibilityHint("Drag to move the pointer. Tap to click.")
                .accessibilityAddTraits(.allowsDirectInteraction)
                .accessibilityAction(named: "Click") { click(.left) }
                .accessibilityAction(named: "Right-click") { click(.right) }
            }
            keyRow
        }
        .padding(16)
        .background {
            KeyboardCapture(isActive: $typing, strength: hapticsStrength, onText: sendTyped, onBackspace: { pointer.tapKey(.backspace) },
                            onKey: { pointer.tapKey($0) })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(isLive)
        .opacity(isLive ? 1 : 0.4)
        .onChange(of: isLive) { _, live in
            if !live { typing = false }
        }
        .onDisappear { typing = false }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key(typing ? "keyboard.chevron.compact.down" : "keyboard",
                    typing ? "Hide keyboard" : "Show keyboard") { typing.toggle() }
                key(text: "Esc", "Escape") { pointer.tapKey(.escape) }
                key("arrow.right.to.line", "Tab") { pointer.tapKey(.tab) }
                key("arrow.left", "Left arrow") { pointer.tapKey(.left) }
                key("arrow.up", "Up arrow") { pointer.tapKey(.up) }
                key("arrow.down", "Down arrow") { pointer.tapKey(.down) }
                key("arrow.right", "Right arrow") { pointer.tapKey(.right) }
                key("return", "Enter") { pointer.tapKey(.enter) }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .sensoryFeedback(trigger: keyTaps) { _, _ in
            hapticsStrength.tapIntensity.map { SensoryFeedback.impact(weight: .light, intensity: Double($0)) }
        }
    }

    private func key(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        keyButton(label, action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
        }
    }

    private func key(text: String, _ label: String, action: @escaping () -> Void) -> some View {
        keyButton(label, action: action) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    private func keyButton<Label: View>(_ label: String, action: @escaping () -> Void,
                                        @ViewBuilder content: () -> Label) -> some View {
        Button {
            keyTaps += 1
            action()
        } label: {
            content().frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    private func click(_ button: MouseButton) {
        pointer.send(.button(button, down: true))
        pointer.send(.button(button, down: false))
    }

    private func sendTyped(_ text: String) {
        for event in KeyboardTranslator.events(for: text) {
            switch event {
            case .text(let run): pointer.sendText(run)
            case .key(let key): pointer.tapKey(key)
            }
        }
    }
}

/// UIKit touch handling: SwiftUI gestures can't count fingers or report touch timestamps.
struct TrackpadSurface: UIViewRepresentable {
    let isLive: Bool
    var strength: HapticsStrength = .medium
    let onTouch: () -> Void
    let onEvents: ([PointerEvent]) -> Void

    func makeUIView(context: Context) -> TrackpadTouchView {
        let view = TrackpadTouchView()
        view.onEvents = onEvents
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: TrackpadTouchView, context: Context) {
        uiView.onEvents = onEvents
        uiView.onTouch = onTouch
        uiView.strength = strength
        // The stream dropped: never leave the mouse button stuck down.
        if !isLive { uiView.releaseAll() }
    }
}

final class TrackpadTouchView: UIView {
    var onEvents: (([PointerEvent]) -> Void)?
    /// Called when a finger lands, so the tab can put the keyboard away.
    var onTouch: (() -> Void)?
    var strength: HapticsStrength = .medium
    private let clickHaptic = UIImpactFeedbackGenerator(style: .light)
    private var interpreter = TrackpadInterpreter()
    private var active = Set<UITouch>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        // VoiceOver passes touches straight through, so the pointer can still be moved.
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { clickHaptic.prepare() }
    }

    /// Leaving the screen mid-drag must not leave the button down on the PC.
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { releaseAll() }
        super.willMove(toWindow: newWindow)
    }

    /// Forgets every touch and lets go of the left button if a drag had it down.
    func releaseAll() {
        active.removeAll()
        emit(interpreter.cancelAndRelease())
    }

    private var centroid: CGPoint {
        guard !active.isEmpty else { return .zero }
        let sum = active.reduce(CGPoint.zero) { total, touch in
            let point = touch.location(in: self)
            return CGPoint(x: total.x + point.x, y: total.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(active.count), y: sum.y / CGFloat(active.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?()
        active.formUnion(touches)
        emit(interpreter.touchesBegan(fingers: active.count, centroid: centroid, at: touches.first?.timestamp ?? 0))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(interpreter.touchesMoved(fingers: active.count, centroid: centroid))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        emit(interpreter.touchesEnded(remainingFingers: active.count, at: touches.first?.timestamp ?? 0))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        if active.isEmpty {
            emit(interpreter.cancelAndRelease())
        } else {
            // Some fingers are still down: keep the interpreter's finger count in step.
            emit(interpreter.touchesEnded(remainingFingers: active.count, at: touches.first?.timestamp ?? 0))
        }
    }

    private func emit(_ events: [PointerEvent]) {
        guard !events.isEmpty else { return }
        if events.contains(where: { event in
            if case .button(let button, true) = event { return button == .left || button == .right }
            return false
        }) {
            if let intensity = strength.tapIntensity {
                clickHaptic.impactOccurred(intensity: intensity)
                clickHaptic.prepare()
            }
        }
        onEvents?(events)
    }
}

/// An invisible view that owns the phone keyboard while typing is on.
struct KeyboardCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    var strength: HapticsStrength = .medium
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onKey: (VirtualKey) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        KeyCaptureView()
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onText = onText
        view.onBackspace = onBackspace
        view.onKey = onKey
        view.strength = strength
        let binding = $isActive
        view.onResign = { if binding.wrappedValue { binding.wrappedValue = false } }
        if isActive, !view.isFirstResponder {
            // Deferred so the view is in a window; re-check, since typing may have turned off meanwhile.
            Task { @MainActor in
                if binding.wrappedValue, !view.isFirstResponder { _ = view.becomeFirstResponder() }
            }
        } else if !isActive, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}

/// Receives keyboard input and forwards it as-is: no autocorrect, no smart punctuation.
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onResign: (() -> Void)?
    var onKey: ((VirtualKey) -> Void)?
    var strength: HapticsStrength = .medium

    /// Every key taps back, at the user's strength.
    private func keyTap() {
        if let intensity = strength.tapIntensity { haptic.impactOccurred(intensity: intensity) }
    }
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Keys that stay on top of the phone keyboard: the key row underneath is hidden while it is up.
    private lazy var accessoryBar: UIInputView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 56), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
        ])
        stack.addArrangedSubview(barButton(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
            _ = self?.resignFirstResponder()
        })
        stack.addArrangedSubview(barButton(title: "Esc", label: "Escape") { [weak self] in self?.onKey?(.escape) })
        stack.addArrangedSubview(barButton(symbol: "arrow.right.to.line", label: "Tab") { [weak self] in self?.onKey?(.tab) })
        stack.addArrangedSubview(barButton(symbol: "arrow.left", label: "Left arrow") { [weak self] in self?.onKey?(.left) })
        stack.addArrangedSubview(barButton(symbol: "arrow.up", label: "Up arrow") { [weak self] in self?.onKey?(.up) })
        stack.addArrangedSubview(barButton(symbol: "arrow.down", label: "Down arrow") { [weak self] in self?.onKey?(.down) })
        stack.addArrangedSubview(barButton(symbol: "arrow.right", label: "Right arrow") { [weak self] in self?.onKey?(.right) })
        return bar
    }()

    override var inputAccessoryView: UIView? { accessoryBar }

    private func barButton(symbol: String? = nil, title: String? = nil, label: String,
                           action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        if let symbol { configuration.image = UIImage(systemName: symbol) }
        if let title {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold),
            ]))
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.keyTap()
            action()
        })
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { haptic.prepare() }
        return became
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override var canBecomeFirstResponder: Bool { true }

    /// Always true, so the delete key keeps sending backspaces to the PC.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        keyTap()
        onText?(text)
    }

    func deleteBackward() {
        keyTap()
        onBackspace?()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
