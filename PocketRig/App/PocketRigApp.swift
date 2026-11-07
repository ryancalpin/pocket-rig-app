import SwiftUI
import SwiftData

@main
struct PocketRigApp: App {
    /// Finishes tip purchases that complete outside the About screen.
    private let tipObserver = TipTransactionObserver()

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(for: [Host.self, StreamPreferences.self, ControlLayout.self, FeelSettings.self])
    }
}
