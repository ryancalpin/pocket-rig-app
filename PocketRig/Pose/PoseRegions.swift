import CoreGraphics

/// Where the game picture and the deck go for a pose, in the stream screen's own coordinates.
struct PoseRegions: Equatable, Sendable {
    var game: CGRect
    /// Nil when sideways: the buttons float over the full-screen game.
    var deck: CGRect?

    static func make(pose: Pose, size: CGSize, fold: CGRect?) -> PoseRegions {
        let w = size.width, h = size.height
        switch pose {
        case .laptop:
            // Clamped into the window, so a stale fold from before a resize can't give a negative frame.
            let top = min(max(fold?.minY ?? h / 2, 0), h)
            let bottom = min(max(fold?.maxY ?? h / 2, top), h)
            return PoseRegions(game: CGRect(x: 0, y: 0, width: w, height: top),
                               deck: CGRect(x: 0, y: bottom, width: w, height: max(h - bottom, 0)))
        case .book:
            let left = min(max(fold?.minX ?? w / 2, 0), w)
            let right = min(max(fold?.maxX ?? w / 2, left), w)
            return PoseRegions(game: CGRect(x: 0, y: 0, width: left, height: h),
                               deck: CGRect(x: right, y: 0, width: max(w - right, 0), height: h))
        case .upright, .cover:
            // The top third, but never taller than 16:9: on a narrow iPhone a third is taller than the picture.
            let gameHeight = min(h / 3, w * 9 / 16).rounded()
            return PoseRegions(game: CGRect(x: 0, y: 0, width: w, height: gameHeight),
                               deck: CGRect(x: 0, y: gameHeight, width: w, height: h - gameHeight))
        case .sideways:
            return PoseRegions(game: CGRect(origin: .zero, size: size), deck: nil)
        }
    }

    /// Converts the fold from window coordinates into a view whose top-left corner sits at
    /// `containerOrigin` in the window.
    static func fold(_ foldInWindow: CGRect?, containerOrigin: CGPoint) -> CGRect? {
        foldInWindow?.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
    }
}
