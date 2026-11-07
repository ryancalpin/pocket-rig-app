import AppIntents
import Foundation

/// "Resume last game": opens Pocket Rig, which then starts the last game again. Used by Siri and
/// Shortcuts, the Home Screen widget and the Control Center button.
struct ResumeLastGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume last game"
    static let description = IntentDescription("Opens Pocket Rig and starts the last game you played again.")
    /// Runs with the app in front, straight away.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Where the request is written. Tests point this at their own storage, because the running app
    /// (the test host) would otherwise pick the request up first.
    @MainActor static var store: () -> SharedStore = { SharedStore.standard() }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Written down first, so the app finds it even if it is only just starting.
        Self.store().requestResume(at: .now)
        NotificationCenter.default.post(name: .pocketRigResumeRequested, object: nil)
        return .result()
    }
}
