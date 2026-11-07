import SwiftUI

/// DEBUG `-pr.showPose YES`: what PoseMonitor thinks, as a caption at the top of the screen.
struct PoseOverlay: View {
    let monitor: PoseMonitor

    var body: some View {
        Text(monitor.summary)
            .font(.caption.monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.7)))
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityLabel("Pose: \(monitor.summary)")
    }
}
