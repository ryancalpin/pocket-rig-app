import Foundation

/// What Pocket Rig Helper can do on a PC right now, as listed by `GET /v1/info`.
enum HelperCapability: String, Sendable, CaseIterable {
    case library, downloads, install, play
    case restartSteam = "restart-steam"
    case closeGame = "close-game"
    case sleep, restart, lock
}

/// A PC control on the Quick menu. Raw values are the Helper's action names (`POST /v1/actions/<name>`).
enum PCControl: String, Sendable, CaseIterable, Identifiable {
    case restartSteam = "restart-steam"
    case closeGame = "close-game"
    case sleep, restart, lock

    var id: String { rawValue }

    var capability: HelperCapability {
        switch self {
        case .restartSteam: .restartSteam
        case .closeGame: .closeGame
        case .sleep: .sleep
        case .restart: .restart
        case .lock: .lock
        }
    }
}

/// `GET /v1/info`: who the Helper is and what it can do.
struct HelperInfo: Equatable, Sendable {
    enum SteamState: String, Sendable { case notInstalled, notSetUp, ready, unknown }

    struct Steam: Equatable, Sendable {
        var state: SteamState
        var running: Bool
        var runningAppID: Int?
    }

    /// How to wake the PC: its wired network card, and whether a cable is in.
    struct Wake: Decodable, Equatable, Sendable {
        var mac: String
        var interface: String
        var linkUp: Bool
        var broadcast: String?
    }

    var apiVersion: Int
    var version: String
    var hostname: String
    var capabilities: Set<HelperCapability>
    var steam: Steam
    var wake: Wake?
    /// Whether the PC's desktop is up (Steam and power actions need it). `nil` from an older Helper.
    var desktopReady: Bool?

    func can(_ capability: HelperCapability) -> Bool { capabilities.contains(capability) }

    /// The phone can likely wake this PC: it has a wired card with a cable plugged in.
    var canWake: Bool { wake?.linkUp == true }
}

extension HelperInfo: Decodable {
    private enum CodingKeys: String, CodingKey { case apiVersion, version, hostname, capabilities, steam, wake, desktopReady }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        // Names this app doesn't know yet (from a newer Helper) are skipped.
        let names = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilities = Set(names.compactMap(HelperCapability.init(rawValue:)))
        steam = try c.decode(Steam.self, forKey: .steam)
        wake = try c.decodeIfPresent(Wake.self, forKey: .wake)
        desktopReady = try c.decodeIfPresent(Bool.self, forKey: .desktopReady)
    }
}

extension HelperInfo.Steam: Decodable {
    private enum CodingKeys: String, CodingKey { case state, running, runningAppID }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = HelperInfo.SteamState(rawValue: try c.decode(String.self, forKey: .state)) ?? .unknown
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        runningAppID = try c.decodeIfPresent(Int.self, forKey: .runningAppID)
    }
}

/// One Steam game on the PC (`GET /v1/library`).
struct HelperGame: Equatable, Sendable, Identifiable {
    enum State: String, Sendable {
        case installed, downloading, queued, paused, uninstalling, unknown

        /// One short line, e.g. "Downloading · 15 GB of 37.6 GB".
        func statusText(done: Int64, total: Int64) -> String {
            switch self {
            case .installed: return "Installed"
            case .downloading:
                guard total > 0 else { return "Starting download…" }
                let style = ByteCountFormatStyle(style: .file)
                return "Downloading · \(done.formatted(style)) of \(total.formatted(style))"
            case .queued: return "Waiting to download"
            case .paused: return "Paused"
            case .uninstalling: return "Removing"
            case .unknown: return "Busy"
            }
        }
    }

    var appID: Int
    var name: String
    var state: State
    var sizeOnDisk: Int64
    var lastPlayed: Int64?
    var bytesDownloaded: Int64
    var bytesToDownload: Int64
    var artURL: URL?
    var headerURL: URL?
    /// Installed and playable, but Steam has an update it will apply when the game starts.
    var updatePending = false

    var id: Int { appID }
    var progress: Double { Self.progress(done: bytesDownloaded, total: bytesToDownload) }
    var statusText: String {
        updatePending && state == .installed ? "Update ready" : state.statusText(done: bytesDownloaded, total: bytesToDownload)
    }
    /// Tall library art first, then the wide header.
    var artURLs: [URL] { [artURL, headerURL].compactMap { $0 } }
    var lastPlayedDate: Date? {
        guard let lastPlayed, lastPlayed > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(lastPlayed))
    }

    static func progress(done: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(done) / Double(total), 0), 1)
    }
}

private extension KeyedDecodingContainer {
    func url(_ key: Key) throws -> URL? {
        guard let url = try decodeIfPresent(String.self, forKey: key).flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

extension HelperGame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case appID, name, state, sizeOnDisk, lastPlayed, bytesDownloaded, bytesToDownload, artURL, headerURL, updatePending
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        name = try c.decode(String.self, forKey: .name)
        state = State(rawValue: try c.decode(String.self, forKey: .state)) ?? .unknown
        sizeOnDisk = try c.decodeIfPresent(Int64.self, forKey: .sizeOnDisk) ?? 0
        lastPlayed = try c.decodeIfPresent(Int64.self, forKey: .lastPlayed)
        bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded) ?? 0
        bytesToDownload = try c.decodeIfPresent(Int64.self, forKey: .bytesToDownload) ?? 0
        artURL = try c.url(.artURL)
        headerURL = try c.url(.headerURL)
        updatePending = try c.decodeIfPresent(Bool.self, forKey: .updatePending) ?? false
    }
}

/// One game that isn't fully installed (`GET /v1/downloads`).
struct HelperDownload: Equatable, Sendable, Identifiable {
    var appID: Int
    var name: String
    var state: HelperGame.State
    var bytesDownloaded: Int64
    var bytesToDownload: Int64
    var headerURL: URL?

    var id: Int { appID }
    var progress: Double { HelperGame.progress(done: bytesDownloaded, total: bytesToDownload) }
    var statusText: String { state.statusText(done: bytesDownloaded, total: bytesToDownload) }
    /// For VoiceOver: "40 percent, Downloading · …".
    var accessibilityValue: String { "\(Int((progress * 100).rounded())) percent, \(statusText)" }
}

extension HelperDownload: Decodable {
    private enum CodingKeys: String, CodingKey { case appID, name, state, bytesDownloaded, bytesToDownload, headerURL }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        name = try c.decode(String.self, forKey: .name)
        state = HelperGame.State(rawValue: try c.decode(String.self, forKey: .state)) ?? .unknown
        bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded) ?? 0
        bytesToDownload = try c.decodeIfPresent(Int64.self, forKey: .bytesToDownload) ?? 0
        headerURL = try c.url(.headerURL)
    }
}

/// The Helper took the request (`202`). `confirmOnPC`: Steam may be asking for a click on the PC.
struct HelperAccepted: Decodable, Equatable, Sendable {
    var accepted: Bool
    var confirmOnPC: Bool?
}

/// Why a Helper request didn't work, with plain words for the screen.
enum HelperError: Error, Equatable, Sendable {
    /// Nothing answered: no Helper, the PC is off, or a different network.
    case unreachable
    /// The Helper turned this phone away, or its certificate isn't the one paired.
    case notPaired
    /// The Helper answered no; `code` is its reason (`steam_not_ready`, `too_soon`, …).
    case refused(code: String, status: Int)
    case badReply

    var message: String {
        switch self {
        case .unreachable: return "Can't reach Pocket Rig Helper on your PC. Make sure your PC is on."
        case .notPaired: return "Your PC didn't recognize this phone. Pair it again."
        case .badReply: return "Pocket Rig Helper sent a reply Pocket Rig didn't understand."
        case .refused(let code, _):
            switch code {
            case "steam_not_ready": return "Sign in to Steam on your PC first."
            case "no_desktop": return "Your PC's desktop isn't ready yet. Try again in a minute."
            case "no_game": return "No game is running."
            case "not_installed": return "That game isn't installed yet."
            case "already_installed": return "That game is already installed."
            case "too_soon": return "Your PC is still busy with the last request. Try again in a few seconds."
            case "not_allowed": return "Your PC wants a password for that, so Pocket Rig can't do it."
            case "bad_appid": return "That isn't a Steam game."
            case "game_stuck": return "The game didn't close. You may need to close it on your PC."
            case "steam_stuck": return "Steam didn't close to restart. Try again, or restart your PC."
            case "not_found", "method_not_allowed", "unknown_action": return "Your PC's Helper is out of date. Update Pocket Rig Helper."
            default: return "Your PC couldn't do that. Try again."
            }
        }
    }

    static func message(for error: any Error) -> String {
        (error as? HelperError ?? .refused(code: "failed", status: 0)).message
    }
}
