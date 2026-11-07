import CoreGraphics

/// How the phone is held, as the stream layout cares about it.
enum Pose: String, Codable, CaseIterable, Sendable, Identifiable {
    /// iPhone Duo shut: the small outer (cover) screen.
    case cover
    /// Partly open, fold running left to right (like a laptop): game on top, deck below.
    case laptop
    /// Partly open, fold running top to bottom (like a book): game on one half, deck on the other.
    case book
    /// Fully open, or a regular iPhone, held upright: game in the top third, big deck below.
    case upright
    /// Fully open, or a regular iPhone, held sideways: full-screen game, see-through buttons on top.
    case sideways

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: "Closed"
        case .laptop: "Half-folded"
        case .book: "Book"
        case .upright: "Upright"
        case .sideways: "Sideways"
        }
    }

    /// The fold splits the inner screen.
    var isFolded: Bool { self == .laptop || self == .book }

    /// Poses with their own button layout. Streaming on the cover screen borrows the half-folded one
    /// (its deck is about the same shape; the upright layout overlaps there).
    static let layoutPoses: [Pose] = [.laptop, .book, .upright, .sideways]

    var layoutPose: Pose { self == .cover ? .laptop : self }

    /// The pose the stream screen lays itself out as. A closed phone whose screen is wider than tall
    /// streams like the open sideways pose (full-screen game, see-through buttons): the upright split
    /// would leave a thin strip for the picture. Everything else streams as itself. The classifier and
    /// the closed-phone home screen still see `.cover`.
    func streamingPose(in size: CGSize) -> Pose {
        self == .cover && size.width > size.height ? .sideways : self
    }
}

/// What the classifier looks at. Orientation is the window's shape: wider than tall is landscape.
struct PoseInput: Equatable, Sendable {
    var windowSize: CGSize
    /// Where the fold crosses the window. iOS reports it only while the phone is partly open.
    var fold: CGRect?
    /// iOS has reported a hinge on this device at least once (iPhone Duo).
    var hasHinge: Bool
}

enum PoseClassifier {
    /// The cover screen's short side is 466 pt and the inner screen's 669 pt.
    static let coverMaxShortSide: CGFloat = 560
    /// The cover screen is squat (466 × 678 ≈ 0.69). Regular iPhones are about 0.46, iPhone SE 0.56.
    static let coverMinAspect: CGFloat = 0.62

    static func classify(_ input: PoseInput) -> Pose {
        let size = input.windowSize
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        guard short > 0 else { return .upright }
        if let fold = input.fold, fold.width > 0 || fold.height > 0 {
            return fold.width >= fold.height ? .laptop : .book
        }
        if short < coverMaxShortSide, input.hasHinge || short / long >= coverMinAspect {
            return .cover
        }
        return size.width > size.height ? .sideways : .upright
    }
}
