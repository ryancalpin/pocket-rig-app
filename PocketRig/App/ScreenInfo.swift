import UIKit

@MainActor
enum ScreenInfo {
    /// 120 on ProMotion screens, 60 elsewhere.
    static var maximumFramesPerSecond: Int {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.maximumFramesPerSecond ?? 60
    }
}
