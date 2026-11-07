import Foundation
import Observation
import UIKit

/// Runs "Wake PC" for any screen that offers it (the closed-phone cover and the PC list), so both use
/// the same rules, haptics and messages. It sends Wake-on-LAN, then checks every 5 seconds for a minute
/// whether the PC came up. The notices live here, so they survive the screen being rebuilt.
@MainActor @Observable
final class WakeCoordinator {
    /// A line under a PC after Wake PC, keyed by the PC's server ID (or a demo name).
    private(set) var notices: [String: String] = [:]
    private(set) var waking: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let checks: Int
    @ObservationIgnored private let pause: Duration

    init(checks: Int = 12, pause: Duration = .seconds(5)) {
        self.checks = checks
        self.pause = pause
    }

    func isWaking(_ id: String) -> Bool { waking.contains(id) }

    func clearNotice(_ id: String) {
        if notices[id] != nil { notices[id] = nil }
    }

    /// Stops every follow-up check (the screen went away), without leaving "Waking…" behind.
    func stopAll() {
        for task in tasks.values { task.cancel() }
    }

    /// Wake rules: only an offline PC with a valid saved network-card address is offered the button.
    static func canOffer(status: CoverHostStatus?, macAddress: String?) -> Bool {
        status == .offline && macAddress.map(WakeOnLAN.isValidMAC) == true
    }

    /// `host` is nil for demo entries, which have no PC behind them: the message is all they show.
    func start(id: String, host: Host?, model: AppModel) {
        guard !waking.contains(id) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        waking.insert(id)
        notices[id] = WakeOnLAN.wakingMessage
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self, checks, pause] in
            defer {
                self?.waking.remove(id)
                self?.tasks[id] = nil
                // Stopped early (the screen went away): don't leave "Waking…" on screen.
                if Task.isCancelled { self?.notices[id] = nil }
            }
            guard let host else { return }
            guard await model.wake(host) else {
                self?.notices[id] = WakeOnLAN.notSentMessage
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            for _ in 0..<checks {
                try? await Task.sleep(for: pause)
                if Task.isCancelled { return }
                // The regular refresh may have seen the PC come up already.
                if model.coverStatuses[id]?.isOnline == true {
                    self?.notices[id] = nil
                    return
                }
                if await model.probeHost(host, checkHelper: true)?.isOnline == true {
                    self?.notices[id] = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                }
            }
            self?.notices[id] = WakeOnLAN.noAnswerMessage
        }
    }
}
