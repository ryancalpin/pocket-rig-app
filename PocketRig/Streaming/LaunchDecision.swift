import Foundation

/// What to do when the user picks a game, given what the PC is already running.
enum LaunchDecision: Equatable {
    /// Nothing is running; start the picked game.
    case start
    /// The picked game is the one already running; rejoin it.
    case resume
    /// A different game is running; starting this one would quit it, so ask first.
    case confirmQuit

    /// `runningAppID` is serverinfo's `currentgame` (0 means nothing is running).
    static func decide(runningAppID: Int, selectedAppID: Int) -> LaunchDecision {
        if runningAppID == 0 { return .start }
        return runningAppID == selectedAppID ? .resume : .confirmQuit
    }

    static let unknownGameTitle = "the game that's running"

    /// Title for the "quit?" dialog.
    static func confirmTitle(runningTitle: String?) -> String {
        "Quit \(runningTitle ?? unknownGameTitle) on your PC?"
    }
}
