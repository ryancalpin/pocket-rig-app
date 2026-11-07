import Foundation

/// Reads a Steam app number out of whatever the user pasted: the number itself, a store, community,
/// SteamDB or s.team link, or a steam:// link. Anything else is nil, so nothing odd reaches the PC.
enum SteamLink {
    private static let webHosts = ["steampowered.com", "steamcommunity.com", "steamdb.info"]
    private static let steamVerbs: Set<String> = ["install", "run", "rungameid", "store"]

    static func appID(from raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = number(stripped(text)) { return id }
        // Shared text often wraps the link in words: try each word that could be a link.
        for word in text.split(whereSeparator: \.isWhitespace) where word.contains(":") {
            if let id = fromURL(stripped(String(word))) { return id }
        }
        return nil
    }

    private static let leadingPunctuation = CharacterSet(charactersIn: "(<[\"'")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]>\"'")

    /// "(https://…/app/570)." and "570." are what people paste out of sentences.
    private static func stripped(_ text: String) -> String {
        text.trimmingCharacters(in: leadingPunctuation).trimmingCharacters(in: trailingPunctuation)
    }

    /// 1…4294967295, digits only.
    private static func number(_ text: some StringProtocol) -> Int? {
        guard !text.isEmpty, text.count <= 10, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), value > 0, value <= Int(UInt32.max) else { return nil }
        return value
    }

    private static func fromURL(_ text: String) -> Int? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch scheme {
        case "https", "http":
            if host == "s.team" {
                guard parts.count >= 2, parts[0] == "a" else { return nil }
                return number(parts[1])
            }
            guard webHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  let index = parts.firstIndex(where: { $0.lowercased() == "app" }), index + 1 < parts.count else {
                return nil
            }
            return number(parts[index + 1])
        case "steam":
            // steam://install/570 parses as host "install", path "/570".
            guard steamVerbs.contains(host), let first = parts.first else { return nil }
            return number(first)
        default:
            return nil
        }
    }
}

/// Steam's public art for a game.
enum SteamArt {
    private static let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/"

    /// Tall library art (600×900). Some older games don't have it.
    static func portrait(_ appID: Int) -> URL { URL(string: "\(base)\(appID)/library_600x900.jpg")! }

    /// Wide store header (460×215). Every game has one.
    static func header(_ appID: Int) -> URL { URL(string: "\(base)\(appID)/header.jpg")! }
}

/// Playing a Steam game: start it on the PC through the Helper, then stream Sunshine's Desktop app.
enum SteamPlay {
    static let noDesktopMessage = "Add an app called Desktop in Sunshine on your PC to play Steam games from here."
    static let desktopNotReadyMessage = "Your PC's desktop isn't ready yet. Try again in a minute."

    /// What "Play" should do, decided without any screen: the one rule for Play, in one place.
    enum PlayPlan: Equatable {
        case desktopNotReady
        case noDesktop
        case go(desktop: HostApp, decision: LaunchDecision)
    }

    static func plan(apps: [HostApp], runningAppID: Int, desktopReady: Bool) -> PlayPlan {
        guard desktopReady else { return .desktopNotReady }
        guard let desktop = desktopApp(in: apps) else { return .noDesktop }
        return .go(desktop: desktop, decision: LaunchDecision.decide(runningAppID: runningAppID, selectedAppID: desktop.id))
    }

    static func desktopApp(in apps: [HostApp]) -> HostApp? {
        apps.first { $0.title.compare("Desktop", options: .caseInsensitive) == .orderedSame }
    }

    /// Installed games first (most recently played, then A–Z), then downloads (A–Z).
    static func sorted(_ games: [HelperGame]) -> [HelperGame] {
        games.sorted { a, b in
            let aInstalled = a.state == .installed
            let bInstalled = b.state == .installed
            if aInstalled != bInstalled { return aInstalled }
            if aInstalled, (a.lastPlayed ?? 0) != (b.lastPlayed ?? 0) { return (a.lastPlayed ?? 0) > (b.lastPlayed ?? 0) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// How often the open app list re-reads the Steam library: quickly while something is downloading.
enum LibraryRefresh {
    static let busy: Duration = .seconds(5)
    static let idle: Duration = .seconds(30)

    static func interval(for games: [HelperGame]?) -> Duration {
        (games ?? []).contains { $0.state != .installed } ? busy : idle
    }
}
