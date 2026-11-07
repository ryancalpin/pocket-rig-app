import CoreGraphics

/// A stream resolution in pixels.
struct PixelSize: Equatable, Hashable, Codable, Sendable {
    var width: Int
    var height: Int

    var title: String { "\(width) × \(height)" }
}

/// The most detail the user wants to stream (Quick menu › Quality).
enum ResolutionCap: String, Codable, CaseIterable, Sendable, Identifiable {
    case p720, p1080

    var id: String { rawValue }
    /// Longest side allowed, whichever way round the picture is.
    var long: Int { self == .p720 ? 1280 : 1920 }
    var short: Int { self == .p720 ? 720 : 1080 }
    var size: PixelSize { PixelSize(width: long, height: short) }
    var title: String { self == .p720 ? "720p · uses less data" : "1080p · sharpest" }
}

/// Picks a stream resolution that exactly fills the game area, so the phone never resizes the picture.
enum StreamSizing {
    /// Hardware encoders want sides that are multiples of 8 (2 is the hard minimum for 4:2:0 video).
    static let alignment = 8
    static let minimumSide = 64

    /// `points` × `scale`, shrunk (keeping its shape) to fit the cap and the host's encoder limit, then
    /// rounded down to multiples of 8. A cap is orientation-free: a tall area gets 1080 wide × up to 1920 tall.
    static func pixelSize(points: CGSize, scale: CGFloat, cap: ResolutionCap, maxPixels: Int? = nil) -> PixelSize {
        let w = Double(points.width * scale), h = Double(points.height * scale)
        guard w > 0, h > 0 else { return cap.size }
        let long = max(w, h), short = min(w, h)
        var factor = min(1, Double(cap.long) / long, Double(cap.short) / short)
        if let maxPixels, maxPixels > 0 {
            factor = min(factor, (Double(maxPixels) / (w * h)).squareRoot())
        }
        return PixelSize(width: align(w * factor), height: align(h * factor))
    }

    /// The pixel size for a pose's game area inside a stream screen of `containerSize` points.
    static func gamePixelSize(pose: Pose, containerSize: CGSize, fold: CGRect?, scale: CGFloat,
                              cap: ResolutionCap, maxPixels: Int? = nil) -> PixelSize {
        let game = PoseRegions.make(pose: pose, size: containerSize, fold: fold).game
        return pixelSize(points: game.size, scale: scale, cap: cap, maxPixels: maxPixels)
    }

    private static func align(_ value: Double) -> Int {
        // The tiny nudge stops 1079.9999 (floating-point noise) from rounding down to 1072.
        max(minimumSide, Int((value + 0.001) / Double(alignment)) * alignment)
    }
}
