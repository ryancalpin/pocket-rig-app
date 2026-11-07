import AppIntents

/// Siri phrases, ready without any setup.
struct PocketRigShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeLastGameIntent(),
                    phrases: [
                        "Resume my game in \(.applicationName)",
                        "Resume last game in \(.applicationName)",
                        "Continue playing in \(.applicationName)",
                    ],
                    shortTitle: "Resume last game",
                    systemImageName: "gamecontroller.fill")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
