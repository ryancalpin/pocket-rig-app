import SwiftUI

// The only file that calls the iPhone Duo APIs of the iOS 27.1 SDK: SwiftUI's
// `onHingeChange(isEnabled:_:)`, `DeviceHinge`, and
// `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)`. Everything else reads the
// plain values below, so if Apple renames something only this file changes. To build without them,
// remove `-DPOCKETRIG_HINGE_API` from project.yml: the cover screen is then still recognised by its
// shape, but the half-folded poses never appear.

/// What the hinge reports, in Pocket Rig's own terms.
struct HingeReading: Equatable, Sendable {
    enum Status: String, Sendable {
        case closed, partiallyOpen, fullyOpen, unknown
    }

    /// 180 when the phone lies flat, 0 when it is shut.
    var angleDegrees: Double
    var status: Status
}

enum DuoHinge {
    /// True when this build includes the iOS 27.1 hinge APIs.
    static var isCompiledIn: Bool {
        #if POCKETRIG_HINGE_API
        true
        #else
        false
        #endif
    }
}

#if POCKETRIG_HINGE_API
@available(iOS 27.1, *)
extension HingeReading {
    init(_ hinge: DeviceHinge) {
        angleDegrees = hinge.angle.degrees
        switch hinge.status {
        case .closed: status = .closed
        case .partiallyOpen: status = .partiallyOpen
        case .fullyOpen: status = .fullyOpen
        default: status = .unknown
        }
    }
}
#endif

extension View {
    /// Reports the hinge (nil on a device without one) whenever it changes.
    @ViewBuilder
    func hingeChanges(_ report: @escaping @MainActor @Sendable (HingeReading?) -> Void) -> some View {
        #if POCKETRIG_HINGE_API
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in
                // The SDK doesn't promise the main thread here.
                let reading = context.hinge.map(HingeReading.init)
                Task { @MainActor in report(reading) }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Reports where the fold crosses the window, in window coordinates: a wide flat rectangle when
    /// half-folded like a laptop, a tall thin one like a book, nil while flat or closed.
    func foldChanges(_ report: @escaping @MainActor @Sendable (CGRect?) -> Void) -> some View {
        background { FoldReader(report: report) }
    }
}

private struct FoldReader: View {
    let report: @MainActor @Sendable (CGRect?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fold = Self.fold(in: proxy)
            Color.clear.onChange(of: fold, initial: true) { _, frame in report(frame) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        #if POCKETRIG_HINGE_API
        if #available(iOS 27.1, *) {
            // Fixed, not mirrored: the game/deck split doesn't flip for right-to-left languages.
            guard let local = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
                .first(where: { $0.isActive })?.frame else { return nil }
            let origin = proxy.frame(in: .global).origin
            return local.offsetBy(dx: origin.x, dy: origin.y)
        }
        #endif
        return nil
    }
}
