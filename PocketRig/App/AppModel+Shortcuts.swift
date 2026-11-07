import Foundation
import WidgetKit

extension PCSnapshot {
    /// nil while the status is still being checked.
    init?(serverUniqueID: String, pcName: String, status: CoverHostStatus, checkedAt: Date) {
        let state: State
        var title: String?
        switch status {
        case .checking: return nil
        case .offline: state = .offline
        case .needsPairing: state = .needsPairing
        case .online(let running, let runningTitle, _):
            state = .online
            title = running == 0 ? nil : runningTitle
        }
        self.init(serverUniqueID: serverUniqueID, pcName: pcName, state: state, runningTitle: title, checkedAt: checkedAt)
    }
}

extension AppModel {
    /// The same status is written again only after this long, so the widget's "as of" time stays roughly true
    /// without a write on every 30-second check.
    static let statusRewriteInterval: TimeInterval = 300

    /// Opens the stream screen for this game and remembers it for "Resume last game".
    func openStream(_ host: Host, appID: Int, appTitle: String, steamGameName: String? = nil, now: Date = .now) {
        recordLaunch(host, appID: appID, appTitle: appTitle, steamGameName: steamGameName, now: now)
        path.append(.stream(serverUniqueID: host.serverUniqueID, appID: appID))
    }

    /// Reopening the same Sunshine app without a Steam name (resuming Desktop) keeps the Steam game's name.
    func recordLaunch(_ host: Host, appID: Int, appTitle: String, steamGameName: String?, now: Date) {
        let previous = sharedStore.lastPlayed
        var name = steamGameName
        if name == nil, let previous, previous.serverUniqueID == host.serverUniqueID, previous.appID == appID {
            name = previous.steamGameName
        }
        // The widget's PC line belongs to the last game's PC; a different PC starts with no status.
        if let pc = sharedStore.pc, pc.serverUniqueID != host.serverUniqueID { sharedStore.pc = nil }
        sharedStore.lastPlayed = LastPlayed(serverUniqueID: host.serverUniqueID, pcName: host.name, appID: appID,
                                            appTitle: appTitle, steamGameName: name, playedAt: now)
        reloadWidgets()
    }

    /// Keeps the widget's PC line current, for the last game's PC only.
    func recordStatus(_ host: Host, status: CoverHostStatus, now: Date = .now) {
        guard let last = sharedStore.lastPlayed, last.serverUniqueID == host.serverUniqueID,
              let snapshot = PCSnapshot(serverUniqueID: host.serverUniqueID, pcName: host.name, status: status,
                                        checkedAt: now) else { return }
        if let old = sharedStore.pc, old.sameStatus(as: snapshot),
           now.timeIntervalSince(old.checkedAt) < Self.statusRewriteInterval { return }
        sharedStore.pc = snapshot
        reloadWidgets()
    }

    /// "Resume last game": goes to the PC's app list, which starts the game once it has loaded (asking first
    /// if a different game is running). Returns what the "Can't resume" alert should say, or nil.
    /// For the game already on screen it asks the stream screen to bring it back from the floating window.
    func resumeLastGame(hosts: [Host], now: Date = .now) -> String? {
        let plan = ResumePlan.make(last: sharedStore.lastPlayed, savedServerIDs: Set(hosts.map(\.serverUniqueID)),
                                   currentPath: path)
        if plan == .alreadyPlaying { showStreamRequests += 1 }
        guard case .open(let serverUniqueID, let appID) = plan else { return plan.message }
        pendingResume = PendingLaunch(serverUniqueID: serverUniqueID, appID: appID, createdAt: now)
        path = [.apps(serverUniqueID: serverUniqueID)]
        return nil
    }

    /// The waiting "Resume last game" for this PC's list, if it is still fresh. A request for this PC is
    /// cleared either way (used now, or too old to act on); one for a different PC is left alone, even
    /// if it has expired.
    func takePendingResume(for serverUniqueID: String, now: Date = .now) -> PendingLaunch? {
        guard let pending = pendingResume, pending.serverUniqueID == serverUniqueID else { return nil }
        pendingResume = nil
        return pending.isExpired(now: now) ? nil : pending
    }

    /// Drops the waiting request when this PC's list can't (or no longer will) act on it.
    func cancelPendingResume(for serverUniqueID: String) {
        if pendingResume?.serverUniqueID == serverUniqueID { pendingResume = nil }
    }

    func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: PocketRigShared.lastGameWidgetKind)
        ControlCenter.shared.reloadControls(ofKind: PocketRigShared.resumeControlKind)
    }
}
