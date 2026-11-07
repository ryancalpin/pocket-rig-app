import SwiftUI

/// Over the game area while the stream plays in the floating window (picture in picture): the picture is
/// in the window, so this says where it went and brings it back.
struct FloatingWindowNotice: View {
    let onBringBack: () -> Void
    @Environment(\.hapticsStrength) private var hapticsStrength
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pip")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("Playing in the floating window")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                taps += 1
                onBringBack()
            } label: {
                Label("Bring it back", systemImage: "pip.exit")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(16)
        .sensoryFeedback(trigger: taps) { _, _ in
            hapticsStrength.tapIntensity.map { SensoryFeedback.impact(weight: .light, intensity: Double($0)) }
        }
    }
}
