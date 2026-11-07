import Foundation
import SwiftData

/// Stream quality the user picked in Quick menu › Quality. One record; changes apply on the next connect.
@Model
final class StreamPreferences {
    var resolutionCapRaw: String
    var fps: Int
    var bitrateKbps: Int
    /// Most data the stream may use away from home, in kbps; 0 means "Same as at home". Optional so
    /// settings saved before Phase 5 still load.
    var awayBitrateKbpsRaw: Int?
    /// Overheat protection on or off. Optional for the same reason.
    var heatProtectionRaw: Bool?

    init(resolutionCap: ResolutionCap = .p1080, fps: Int = 60, bitrateKbps: Int = 20_000) {
        self.resolutionCapRaw = resolutionCap.rawValue
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }

    var resolutionCap: ResolutionCap {
        get { ResolutionCap(rawValue: resolutionCapRaw) ?? .p1080 }
        set { resolutionCapRaw = newValue.rawValue }
    }

    var awayBitrateKbps: Int {
        get { awayBitrateKbpsRaw ?? Self.defaultAwayBitrateKbps }
        set { awayBitrateKbpsRaw = newValue }
    }

    var heatProtection: Bool {
        get { heatProtectionRaw ?? true }
        set { heatProtectionRaw = newValue }
    }

    static let defaultAwayBitrateKbps = 10_000
    /// 0 is "Same as at home".
    static let awayBitrateChoices = [5_000, 10_000, 0]

    static func awayBitrateTitle(_ kbps: Int) -> String {
        switch kbps {
        case 0: return "Same as at home"
        case 5_000: return "Data saver · 5 Mbps"
        case 10_000: return "Balanced · 10 Mbps"
        default: return "\(kbps / 1000) Mbps"
        }
    }

    static let bitrateChoices = [10_000, 20_000, 35_000, 50_000]

    static func bitrateTitle(_ kbps: Int) -> String {
        let mbps = "\(kbps / 1000) Mbps"
        switch kbps {
        case 10_000: return "Data saver · \(mbps)"
        case 20_000: return "Balanced · \(mbps)"
        case 35_000: return "High · \(mbps)"
        case 50_000: return "Best · \(mbps)"
        default: return mbps
        }
    }

    /// 120 fps only shows on screens that can display it.
    static func frameRates(screenMaxFPS: Int) -> [Int] {
        [30, 60, 120].filter { $0 <= max(60, screenMaxFPS) }
    }

    func effectiveFPS(screenMaxFPS: Int) -> Int {
        min(fps, max(60, screenMaxFPS))
    }

    func streamSettings(size: PixelSize, screenMaxFPS: Int, audioEnabled: Bool) -> StreamSettings {
        StreamSettings(width: size.width, height: size.height, fps: effectiveFPS(screenMaxFPS: screenMaxFPS),
                       bitrateKbps: bitrateKbps, audioEnabled: audioEnabled)
    }

    /// The saved preferences, created with defaults the first time.
    @MainActor
    static func current(in context: ModelContext) -> StreamPreferences {
        if let saved = try? context.fetch(FetchDescriptor<StreamPreferences>()).first { return saved }
        let fresh = StreamPreferences()
        context.insert(fresh)
        try? context.save()
        return fresh
    }
}
