import ActivityKit
import Foundation

/// One Steam download on one PC, shown in the Dynamic Island and on the Lock Screen.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var appID: Int
        var name: String
        /// 0…1, in whole percents.
        var progress: Double
        /// "Downloading", "Paused", "Waiting to download", "Ready to play", "Stopped downloading".
        var statusText: String
        /// Other downloads behind this one.
        var waitingCount: Int
        var finished: Bool

        var percentText: String {
            finished && progress >= 1 ? "Done" : "\(Int((progress * 100).rounded()))%"
        }

        var waitingText: String? {
            switch waitingCount {
            case 0: nil
            case 1: "1 more waiting"
            default: "\(waitingCount) more waiting"
            }
        }

        var symbol: String {
            if finished { return progress >= 1 ? "checkmark.circle.fill" : "stop.circle.fill" }
            return statusText == "Paused" ? "pause.circle.fill" : "arrow.down.circle.fill"
        }
    }

    var serverUniqueID: String
    var pcName: String

    /// Shown once the app hasn't updated the activity for a while: it isn't running, or a game is streaming
    /// (the app doesn't check the PC's downloads then). True in both cases, unlike "Open Pocket Rig".
    static let staleNote = "Progress may be out of date"
}
