import Foundation

/// Runs one action at a set time on the main actor; scheduling again replaces it. Tests turn it off,
/// move a fake clock and call the action themselves.
@MainActor
final class WakeupTimer {
    private let enabled: Bool
    private var task: Task<Void, Never>?

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func schedule(in delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        guard enabled else { return }
        let wait = max(delay, 0.001)
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(1))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
