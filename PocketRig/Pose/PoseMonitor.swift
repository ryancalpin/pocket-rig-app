import Observation
import SwiftUI

/// One shared answer to "how is the phone held?" The root view feeds it (window size, fold, hinge);
/// everything else reads `pose`.
///
/// Settling: a change into or out of a half-fold must hold for `settleDelay` before the layout
/// follows, so a wobbly hinge doesn't flip the screen back and forth. Closing the phone, opening it,
/// and rotating are deliberate, so they apply at once.
@MainActor @Observable
final class PoseMonitor {
    nonisolated static let defaultSettleDelay: Duration = .milliseconds(350)

    private(set) var pose: Pose = .upright
    /// The latest hinge reading, unsmoothed (pose caption).
    private(set) var hinge: HingeReading?
    /// Where the fold crosses the window, in window coordinates.
    private(set) var foldInWindow: CGRect?
    private(set) var windowSize: CGSize = .zero
    /// iOS has reported a hinge at least once.
    private(set) var hasHinge = false

    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var hasDecided = false

    init(settleDelay: Duration = PoseMonitor.defaultSettleDelay) {
        self.settleDelay = settleDelay
    }

    // MARK: Inputs

    func hingeChanged(_ reading: HingeReading?) {
        hinge = reading
        if reading != nil { hasHinge = true }
        evaluate()
    }

    func foldChanged(_ frame: CGRect?) {
        foldInWindow = frame
        evaluate()
    }

    func windowChanged(_ size: CGSize) {
        windowSize = size
        evaluate()
    }

    // MARK: Deciding

    /// What the pose would be right now, before settling.
    var candidate: Pose {
        PoseClassifier.classify(PoseInput(windowSize: windowSize, fold: foldInWindow, hasHinge: hasHinge))
    }

    private func evaluate() {
        let next = candidate
        settleTask?.cancel()
        settleTask = nil
        let isFirst = !hasDecided && windowSize.width > 0
        if windowSize.width > 0 { hasDecided = true }
        guard next != pose else { return }
        let wobbly = (next.isFolded || pose.isFolded) && next != .cover && pose != .cover
        guard wobbly, !isFirst, settleDelay > .zero else {
            apply(next)
            return
        }
        let delay = settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.candidate == next else { return }
            self.apply(next)
        }
    }

    private func apply(_ next: Pose) {
        // With Reduce Motion on, the layout snaps to the new pose instead of sliding.
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: 0.3)) { pose = next }
    }

    /// "Half-folded · 120° · partiallyOpen · fold 0,465 669×21 · 669×951 pt" for the DEBUG caption.
    var summary: String {
        var parts = [pose.title]
        if let hinge {
            parts.append("\(Int(hinge.angleDegrees.rounded()))°")
            parts.append(hinge.status.rawValue)
        } else {
            parts.append(hasHinge ? "no reading" : "no hinge")
        }
        if let fold = foldInWindow {
            parts.append("fold \(Int(fold.minX)),\(Int(fold.minY)) \(Int(fold.width))×\(Int(fold.height))")
        }
        parts.append("\(Int(windowSize.width))×\(Int(windowSize.height)) pt")
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Feeds the pose monitor. Apply it to the view that fills the window.
    func poseTracking(_ monitor: PoseMonitor) -> some View {
        hingeChanges { monitor.hingeChanged($0) }
            .foldChanges { monitor.foldChanged($0) }
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size, initial: true) { _, size in monitor.windowChanged(size) }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
    }
}
