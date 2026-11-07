import Foundation
import Network
import Observation

/// Whether the phone is on mobile data or Low Data Mode, as it changes. `-pr.networkDemo cellular|lowData`
/// (DEBUG) pretends, for screenshots.
@MainActor @Observable final class NetworkWatcher {
    private(set) var snapshot: NetworkSnapshot
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let demo: NetworkSnapshot?

    init(demo: NetworkSnapshot? = NetworkWatcher.demoFromLaunchOptions()) {
        self.demo = demo
        snapshot = demo ?? .home
    }

    func start() {
        guard demo == nil, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkSnapshot(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            // The monitor reports on the main queue (see `start(queue:)` below).
            MainActor.assumeIsolated { self?.update(snapshot) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func update(_ new: NetworkSnapshot) {
        if snapshot != new { snapshot = new }
    }

    nonisolated static func demo(from text: String?) -> NetworkSnapshot? {
        switch text {
        case "cellular": NetworkSnapshot(isExpensive: true)
        case "lowData": NetworkSnapshot(isConstrained: true)
        default: nil
        }
    }

    nonisolated static func demoFromLaunchOptions() -> NetworkSnapshot? {
        demo(from: DebugLaunchOptions.text("networkDemo"))
    }
}

/// The phone's thermal state, as it changes. `-pr.thermalDemo fair|serious|critical` (DEBUG) pretends.
@MainActor @Observable final class ThermalWatcher {
    private(set) var state: ProcessInfo.ThermalState
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let demo: ProcessInfo.ThermalState?

    init(demo: ProcessInfo.ThermalState? = ThermalWatcher.demoFromLaunchOptions()) {
        self.demo = demo
        state = demo ?? ProcessInfo.processInfo.thermalState
    }

    func start() {
        guard demo == nil, observer == nil else { return }
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Reads the state again (a missed notification is caught on the stream screen's 30-second look).
    func refresh() {
        let now = demo ?? ProcessInfo.processInfo.thermalState
        if state != now { state = now }
    }

    nonisolated static func demo(from text: String?) -> ProcessInfo.ThermalState? {
        switch text {
        case "fair": .fair
        case "serious": .serious
        case "critical": .critical
        default: nil
        }
    }

    nonisolated static func demoFromLaunchOptions() -> ProcessInfo.ThermalState? {
        demo(from: DebugLaunchOptions.text("thermalDemo"))
    }
}
