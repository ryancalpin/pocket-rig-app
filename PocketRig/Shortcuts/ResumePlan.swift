import Foundation

/// Where "Resume last game" goes.
enum ResumePlan: Equatable {
    case nothingSaved
    case pcRemoved(name: String)
    /// That game is already on screen.
    case alreadyPlaying
    case open(serverUniqueID: String, appID: Int)

    static func make(last: LastPlayed?, savedServerIDs: Set<String>, currentPath: [Route]) -> ResumePlan {
        guard let last else { return .nothingSaved }
        guard savedServerIDs.contains(last.serverUniqueID) else { return .pcRemoved(name: last.pcName) }
        if currentPath.last == .stream(serverUniqueID: last.serverUniqueID, appID: last.appID) { return .alreadyPlaying }
        return .open(serverUniqueID: last.serverUniqueID, appID: last.appID)
    }

    /// What the "Can't resume" alert says; nil when nothing needs saying.
    var message: String? {
        switch self {
        case .nothingSaved: "Nothing to resume yet. Play a game in Pocket Rig first, then try again."
        case .pcRemoved(let name): "\(name) isn't in Pocket Rig anymore. Add it again to resume."
        case .alreadyPlaying, .open: nil
        }
    }
}

/// A game the app list should start as soon as it has loaded (from "Resume last game").
struct PendingLaunch: Equatable, Sendable {
    let serverUniqueID: String
    let appID: Int
    /// When "Resume last game" asked. An old request is dropped, never acted on later.
    var createdAt: Date = .now

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > PocketRigShared.resumeRequestLifetime
    }
}
