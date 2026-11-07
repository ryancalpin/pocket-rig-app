import ActivityKit
import Foundation
import os

private let activityLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "liveActivity")

/// Which download the Live Activity shows, and what changes.
enum DownloadActivityPlan {
    typealias State = DownloadActivityAttributes.ContentState

    enum Step: Equatable {
        case none
        case start(State)
        case update(State)
        case finish(State)
    }

    /// A download this close to done that leaves the list has finished.
    static let doneThreshold = 0.95

    /// The downloading game first, else a paused one, else a waiting one. Installed games don't count.
    static func content(for downloads: [HelperDownload]) -> State? {
        let order: [HelperGame.State] = [.downloading, .paused, .queued]
        guard let lead = order.lazy.compactMap({ state in downloads.first { $0.state == state } }).first else {
            return nil
        }
        let waiting = downloads.filter { $0.appID != lead.appID && order.contains($0.state) }.count
        // Rounded down and held under 100: "Downloading" never claims 100%.
        let percent = min((lead.progress * 100 + 1e-9).rounded(.down), 99)
        return State(appID: lead.appID, name: lead.name, progress: percent / 100,
                     statusText: statusText(lead.state), waitingCount: waiting, finished: false)
    }

    static func step(current: State?, downloads: [HelperDownload]) -> Step {
        let next = content(for: downloads)
        guard let current, !current.finished else {
            return next.map { .start($0) } ?? .none
        }
        guard let next else {
            var done = current
            done.finished = true
            done.waitingCount = 0
            if current.progress >= doneThreshold {
                done.progress = 1
                done.statusText = "Ready to play"
            } else {
                done.statusText = "Stopped downloading"
            }
            return .finish(done)
        }
        return next == current ? .none : .update(next)
    }

    /// Short on purpose: byte counts would change the activity on every check.
    private static func statusText(_ state: HelperGame.State) -> String {
        switch state {
        case .paused: "Paused"
        case .queued: "Waiting to download"
        default: "Downloading"
        }
    }
}

struct ShownDownloadActivity: Equatable, Sendable {
    let id: String
    let serverUniqueID: String
    let state: DownloadActivityAttributes.ContentState
}

/// Where activities really go (ActivityKit), or nowhere (tests, and until the app sets the real one).
@MainActor protocol DownloadActivityHosting: AnyObject {
    var isEnabled: Bool { get }
    func existing() -> [ShownDownloadActivity]
    func start(_ attributes: DownloadActivityAttributes, state: DownloadActivityAttributes.ContentState,
               staleDate: Date) async -> String?
    func update(id: String, state: DownloadActivityAttributes.ContentState, staleDate: Date) async
    func end(id: String, state: DownloadActivityAttributes.ContentState, dismissAt: Date) async
}

/// Keeps one Live Activity in step with one PC's downloads. Calls run one after another, in order.
@MainActor final class DownloadActivityController {
    typealias State = DownloadActivityAttributes.ContentState

    /// Past this without an update, the activity says its progress may be out of date.
    static let staleAfter: TimeInterval = 90
    /// A finished download stays this long.
    static let finishedStays: TimeInterval = 600
    /// A failed start isn't tried again for this long.
    static let startRetryAfter: TimeInterval = 60
    /// An unchanged activity is touched this often, so it doesn't look stale while the app is checking.
    static let refreshEvery: TimeInterval = 30

    private let hosting: any DownloadActivityHosting
    private(set) var current: State?
    private var activityID: String?
    private var following: String?
    private var lastPushed: Date?
    private var adopted = false
    /// The last time the followed PC's downloads were read; nil for an activity picked up from an earlier run.
    private var lastUpdated: Date?
    private var startFailedAt: Date?
    private var queue: Task<Void, Never>?

    init(hosting: any DownloadActivityHosting) {
        self.hosting = hosting
    }

    var isShowing: Bool { current.map { !$0.finished } ?? false }

    func update(serverUniqueID: String, pcName: String, downloads: [HelperDownload], now: Date = .now) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.apply(serverUniqueID: serverUniqueID, pcName: pcName, downloads: downloads, now: now)
        }
    }

    /// Call with the PCs now being checked. If the followed PC isn't one of them any more (deleted, unpaired,
    /// no downloads support), its activity is taken away. An activity from an earlier run that this run never
    /// read is left to the silent-PC rule instead, since the PCs may simply not be known yet.
    func keepOnly(serverUniqueIDs: Set<String>, now: Date = .now) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.applyKeepOnly(serverUniqueIDs, now: now)
        }
    }

    func waitUntilIdle() async {
        while let task = queue {
            await task.value
            if queue == task { return }
        }
    }

    private func applyKeepOnly(_ ids: Set<String>, now: Date) async {
        guard let following, lastUpdated != nil, !ids.contains(following) else { return }
        await dropActivity(now: now)
    }

    /// Ends what this controller shows right away and forgets it.
    private func dropActivity(now: Date) async {
        if let id = activityID, let current { await hosting.end(id: id, state: current, dismissAt: now) }
        activityID = nil
        current = nil
        following = nil
        lastUpdated = nil
    }

    private func adoptIfNeeded(now: Date) async {
        guard !adopted else { return }
        // An activity from an earlier run of the app is still on screen: carry on with one, close any others.
        adopted = true
        let all = hosting.existing()
        guard let keep = all.first(where: { !$0.state.finished }) ?? all.first else { return }
        for extra in all where extra.id != keep.id {
            await hosting.end(id: extra.id, state: extra.state, dismissAt: now)
        }
        activityID = keep.id
        following = keep.serverUniqueID
        current = keep.state
        lastPushed = nil
        lastUpdated = nil
    }

    private func apply(serverUniqueID: String, pcName: String, downloads: [HelperDownload], now: Date) async {
        guard hosting.isEnabled else {
            // Live Activities were turned off: don't leave one behind.
            if isShowing { await dropActivity(now: now) }
            return
        }
        await adoptIfNeeded(now: now)
        if following != serverUniqueID {
            // One PC at a time: another PC takes over once this one has nothing going on, or has gone silent.
            let silent = now.timeIntervalSince(lastUpdated ?? .distantPast) > Self.staleAfter
            if isShowing && !silent { return }
            guard DownloadActivityPlan.content(for: downloads) != nil else { return }
            if let startFailedAt, now.timeIntervalSince(startFailedAt) < Self.startRetryAfter { return }
            if let id = activityID, let current { await hosting.end(id: id, state: current, dismissAt: now) }
            activityID = nil
            current = nil
            following = serverUniqueID
        }
        lastUpdated = now
        let stale = now.addingTimeInterval(Self.staleAfter)
        switch DownloadActivityPlan.step(current: current, downloads: downloads) {
        case .none:
            guard isShowing, let id = activityID, let current,
                  now.timeIntervalSince(lastPushed ?? .distantPast) >= Self.refreshEvery else { return }
            await hosting.update(id: id, state: current, staleDate: stale)
            lastPushed = now
        case .start(let state):
            if let startFailedAt, now.timeIntervalSince(startFailedAt) < Self.startRetryAfter { return }
            if let id = activityID, let old = current { await hosting.end(id: id, state: old, dismissAt: now) }
            activityID = await hosting.start(DownloadActivityAttributes(serverUniqueID: serverUniqueID, pcName: pcName),
                                             state: state, staleDate: stale)
            current = activityID == nil ? nil : state
            startFailedAt = activityID == nil ? now : nil
            lastPushed = now
        case .update(let state):
            guard let id = activityID else { return }
            await hosting.update(id: id, state: state, staleDate: stale)
            current = state
            lastPushed = now
        case .finish(let state):
            if let id = activityID {
                await hosting.end(id: id, state: state, dismissAt: now.addingTimeInterval(Self.finishedStays))
            }
            current = state
            lastPushed = now
        }
    }
}

/// ActivityKit. `Activity` isn't Sendable, so it is only touched inside the static functions, found by id.
@MainActor final class LiveDownloadActivities: DownloadActivityHosting {
    typealias State = DownloadActivityAttributes.ContentState

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func existing() -> [ShownDownloadActivity] { Self.findShown() }

    func start(_ attributes: DownloadActivityAttributes, state: State, staleDate: Date) async -> String? {
        Self.request(attributes, state: state, staleDate: staleDate)
    }

    func update(id: String, state: State, staleDate: Date) async {
        await Self.update(id: id, state: state, staleDate: staleDate)
    }

    func end(id: String, state: State, dismissAt: Date) async {
        await Self.end(id: id, state: state, dismissAt: dismissAt)
    }

    nonisolated private static func find(_ id: String) -> Activity<DownloadActivityAttributes>? {
        Activity<DownloadActivityAttributes>.activities.first { $0.id == id }
    }

    nonisolated private static func findShown() -> [ShownDownloadActivity] {
        let onScreen: [ActivityState] = [.pending, .active, .stale]
        return Activity<DownloadActivityAttributes>.activities.filter { onScreen.contains($0.activityState) }.map {
            ShownDownloadActivity(id: $0.id, serverUniqueID: $0.attributes.serverUniqueID, state: $0.content.state)
        }
    }

    nonisolated private static func request(_ attributes: DownloadActivityAttributes, state: State,
                                            staleDate: Date) -> String? {
        do {
            return try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate),
                                        pushType: nil).id
        } catch {
            activityLog.error("Live Activity didn't start: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated private static func update(id: String, state: State, staleDate: Date) async {
        await find(id)?.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated private static func end(id: String, state: State, dismissAt: Date) async {
        await find(id)?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(dismissAt))
    }
}

@MainActor final class NoDownloadActivities: DownloadActivityHosting {
    var isEnabled: Bool { false }
    func existing() -> [ShownDownloadActivity] { [] }
    func start(_ attributes: DownloadActivityAttributes, state: DownloadActivityAttributes.ContentState,
               staleDate: Date) async -> String? { nil }
    func update(id: String, state: DownloadActivityAttributes.ContentState, staleDate: Date) async {}
    func end(id: String, state: DownloadActivityAttributes.ContentState, dismissAt: Date) async {}
}
