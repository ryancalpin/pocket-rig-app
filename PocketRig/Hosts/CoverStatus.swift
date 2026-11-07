/// What the closed-phone screen says about one PC.
enum CoverHostStatus: Equatable, Sendable {
    case checking
    case offline
    case needsPairing
    case online(runningAppID: Int, runningTitle: String?, apps: [HostApp])

    static func make(info: ServerInfo, apps: [HostApp]) -> CoverHostStatus {
        let running = info.currentGameID
        return .online(runningAppID: running, runningTitle: apps.first { $0.id == running }?.title, apps: apps)
    }

    static func failed(_ error: Error) -> CoverHostStatus {
        (error as? HostError) == .notPaired ? .needsPairing : .offline
    }

    var text: String {
        switch self {
        case .checking: "Checking…"
        case .offline: "Offline · Make sure it's on"
        case .needsPairing: "Needs pairing · Open your phone to pair"
        case .online(let id, let title, _):
            id == 0 ? "Online · Nothing running" : "Online · Playing \(title ?? "a game")"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "hourglass"
        case .offline: "power"
        case .needsPairing: "lock.fill"
        case .online: "checkmark.circle.fill"
        }
    }

    /// The app to resume, when one is running.
    var runningAppID: Int? {
        if case .online(let id, _, _) = self, id != 0 { return id }
        return nil
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    var runningTitle: String? {
        if case .online(_, let title, _) = self { return title }
        return nil
    }

    var resumeTitle: String {
        runningTitle.map { "Resume \($0)" } ?? "Resume game"
    }

    var apps: [HostApp] {
        if case .online(_, _, let apps) = self { return apps }
        return []
    }

    #if DEBUG
    /// `-pr.coverDemo YES`: sample PCs for screenshots without a real PC.
    static let demo: [(name: String, status: CoverHostStatus)] = [
        ("Gaming PC", .online(runningAppID: 2, runningTitle: "Hades II",
                              apps: [HostApp(id: 1, title: "Desktop", hdrSupported: false),
                                     HostApp(id: 2, title: "Hades II", hdrSupported: false),
                                     HostApp(id: 3, title: "Steam Big Picture", hdrSupported: false)])),
        ("Office PC", .offline),
    ]
    #endif
}
