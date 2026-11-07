import Foundation

/// Names shared by the app and its widget extension.
enum PocketRigShared {
    /// App Group: storage both the app and the widget extension can read.
    static let appGroup = "group.com.ryancalpin.pocketrig"
    static let lastGameWidgetKind = "LastGameWidget"
    static let resumeControlKind = "com.ryancalpin.pocketrig.resume-control"
    /// A "Resume last game" request older than this is ignored (the app was opened much later).
    static let resumeRequestLifetime: TimeInterval = 60
}

extension Notification.Name {
    /// Posted in the app's process when "Resume last game" runs there.
    static let pocketRigResumeRequested = Notification.Name("com.ryancalpin.pocketrig.resumeRequested")
}

/// The last game streamed. `appTitle` is Sunshine's app (for a Steam game, "Desktop").
struct LastPlayed: Codable, Equatable, Sendable {
    var serverUniqueID: String
    var pcName: String
    var appID: Int
    var appTitle: String
    /// Set when the stream was for a Steam game started through Pocket Rig Helper.
    var steamGameName: String?
    var playedAt: Date

    /// What to call it on the widget: the Steam game when there is one.
    var title: String { steamGameName ?? appTitle }
}

/// What the app last saw of the last game's PC, for the widget.
struct PCSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case online, offline, needsPairing }

    var serverUniqueID: String
    var pcName: String
    var state: State
    var runningTitle: String?
    var checkedAt: Date

    var statusText: String {
        switch state {
        case .online: runningTitle.map { "Playing \($0)" } ?? "Online"
        case .offline: "Offline"
        case .needsPairing: "Needs pairing"
        }
    }

    /// Same PC, same state, same game; only the time differs.
    func sameStatus(as other: PCSnapshot) -> Bool {
        serverUniqueID == other.serverUniqueID && pcName == other.pcName && state == other.state
            && runningTitle == other.runningTitle
    }
}

/// App Group storage. Writes go straight to disk storage that the widget reads.
// UserDefaults is thread-safe.
struct SharedStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The App Group's storage (falls back to the app's own if the group is missing).
    static func standard() -> SharedStore {
        SharedStore(defaults: UserDefaults(suiteName: PocketRigShared.appGroup) ?? .standard)
    }

    private enum Key {
        static let lastPlayed = "lastPlayed"
        static let pc = "pcSnapshot"
        static let resumeRequestedAt = "resumeRequestedAt"
    }

    var lastPlayed: LastPlayed? {
        get { read(Key.lastPlayed) }
        nonmutating set { write(newValue, Key.lastPlayed) }
    }

    var pc: PCSnapshot? {
        get { read(Key.pc) }
        nonmutating set { write(newValue, Key.pc) }
    }

    func requestResume(at date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Key.resumeRequestedAt)
    }

    /// True once for a request made within the last minute. Taking it clears it.
    func takeResumeRequest(now: Date) -> Bool {
        guard defaults.object(forKey: Key.resumeRequestedAt) != nil else { return false }
        let requested = Date(timeIntervalSince1970: defaults.double(forKey: Key.resumeRequestedAt))
        defaults.removeObject(forKey: Key.resumeRequestedAt)
        return now.timeIntervalSince(requested) <= PocketRigShared.resumeRequestLifetime
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
