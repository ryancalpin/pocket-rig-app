import Foundation

/// What a PC control says on the Quick menu.
extension PCControl {
    var title: String {
        switch self {
        case .restartSteam: "Restart Steam"
        case .closeGame: "Close game"
        case .sleep: "Sleep PC"
        case .restart: "Restart PC"
        case .lock: "Lock PC"
        }
    }

    var symbol: String {
        switch self {
        case .restartSteam: "arrow.triangle.2.circlepath"
        case .closeGame: "xmark.app.fill"
        case .sleep: "moon.fill"
        case .restart: "arrow.clockwise"
        case .lock: "lock.fill"
        }
    }

    var confirmTitle: String {
        switch self {
        case .restartSteam: "Restart Steam on your PC?"
        case .closeGame: "Close the game on your PC?"
        case .sleep: "Put your PC to sleep?"
        case .restart: "Restart your PC?"
        case .lock: "Lock your PC?"
        }
    }

    func confirmMessage(canWake: Bool) -> String {
        switch self {
        case .restartSteam: "Steam closes and opens again. A running game closes too."
        case .closeGame: "Unsaved progress in the game may be lost."
        case .sleep:
            canWake ? "The stream ends. You can wake it with Wake PC in Pocket Rig while you're home."
                    : "The stream ends. To wake your PC, you'll need to press its power button."
        case .restart: "The stream ends. Your PC is back in a few minutes."
        case .lock: "Your PC locks its screen. You'll need its password to get back in."
        }
    }

    var confirmButton: String {
        switch self {
        case .restartSteam: "Restart Steam"
        case .closeGame: "Close Game"
        case .sleep: "Sleep"
        case .restart: "Restart"
        case .lock: "Lock"
        }
    }

    /// Gets the red button in the confirmation dialog.
    var isDestructive: Bool { self != .lock }

    var doneMessage: String {
        switch self {
        case .restartSteam: "Steam is restarting"
        case .closeGame: "Game closed"
        case .sleep: "Your PC is going to sleep"
        case .restart: "Your PC is restarting"
        case .lock: "Your PC is locked"
        }
    }

    /// The PC goes away, so the stream screen closes itself.
    var endsStream: Bool { self == .sleep || self == .restart }

    /// How long after the Helper accepts Sleep or Restart the stream screen closes. The Helper acts about
    /// 0.5 s after it replies, so this lands just before the picture would freeze.
    static let streamCloseDelay: Duration = .milliseconds(400)

    /// One line under the PC tiles when some of them are off, saying why.
    static func unavailableNote(for status: HelperStatus) -> String? {
        guard let info = status.info else {
            if status == .needsAppUpdate { return HelperStatus.updateAppNote }
            return status == .unknown ? "Checking for Pocket Rig Helper on your PC…"
                                      : "Install Pocket Rig Helper on your PC to use these."
        }
        // Without a desktop session Steam, Lock and friends can't run; that's a sign-in matter, not a password.
        if info.desktopReady == false { return "Your PC's desktop isn't ready yet. Sign in on the PC to use these." }
        if info.steam.state != .ready { return "Restart Steam and Close game need Steam signed in on your PC." }
        if !allCases.allSatisfy({ info.can($0.capability) }) {
            return "Your PC wants a password for some of these, so they're off."
        }
        return nil
    }
}

/// How a PC control went, for the Quick menu's notice.
struct PCControlResult: Equatable, Sendable {
    /// The stream is up, so the PC is on: if there's no Helper client, the Helper itself isn't answering.
    static let helperNotAnswering = PCControlResult(
        message: "Pocket Rig Helper isn't answering. Check that it's running on your PC.", succeeded: false)

    let message: String
    let succeeded: Bool
}
