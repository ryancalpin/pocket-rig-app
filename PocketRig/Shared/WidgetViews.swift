import AppIntents
import SwiftUI
import WidgetKit

/// What the "Last game" widget shows at one moment.
struct LastGameEntry: TimelineEntry, Equatable, Sendable {
    struct Game: Equatable, Sendable {
        var title: String
        var pcName: String
        /// The PC's status the app last saw ("Online", "Playing Hades II"); nil when it hasn't seen one.
        var status: String?
        var checkedAt: Date?

        /// True when the status was checked less than a minute before `now`.
        func isJustChecked(at now: Date) -> Bool {
            guard let checkedAt else { return false }
            return now.timeIntervalSince(checkedAt) < LastGameEntry.justNowAge
        }
    }

    var date: Date
    var game: Game?

    static let emptyMessage = "Play a game in Pocket Rig and it shows up here."

    /// A PC status older than this is hidden: "Online" from days ago would look current.
    static let statusMaxAge: TimeInterval = 60 * 60
    /// Under this age the widget says "just now" instead of a minute count.
    static let justNowAge: TimeInterval = 60

    static func make(lastPlayed: LastPlayed?, pc: PCSnapshot?, now: Date) -> LastGameEntry {
        guard let lastPlayed else { return LastGameEntry(date: now, game: nil) }
        let samePC = pc.flatMap { $0.serverUniqueID == lastPlayed.serverUniqueID ? $0 : nil }
            .flatMap { now.timeIntervalSince($0.checkedAt) <= statusMaxAge ? $0 : nil }
        return LastGameEntry(date: now, game: Game(title: lastPlayed.title, pcName: lastPlayed.pcName,
                                                    status: samePC?.statusText, checkedAt: samePC?.checkedAt))
    }

    static func make(store: SharedStore, now: Date) -> LastGameEntry {
        make(lastPlayed: store.lastPlayed, pc: store.pc, now: now)
    }

    static var sample: LastGameEntry {
        LastGameEntry(date: .now, game: Game(title: "Baldur's Gate 3", pcName: "Gaming PC", status: "Online",
                                             checkedAt: .now.addingTimeInterval(-120)))
    }

    static var empty: LastGameEntry { LastGameEntry(date: .now, game: nil) }
}

/// The widget's picture, shared by the widget extension and the app's DEBUG gallery.
struct LastGameWidgetView: View {
    let entry: LastGameEntry
    let family: WidgetFamily

    init(entry: LastGameEntry, family: WidgetFamily) {
        self.entry = entry
        self.family = family
    }

    var body: some View {
        content
            // Deliberate cap: a widget has a fixed size, so sizes above xLarge would clip.
            // Larger sizes stop growing here.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    @ViewBuilder private var content: some View {
        if let game = entry.game {
            filled(game)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(LastGameEntry.emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func filled(_ game: LastGameEntry.Game) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(game.pcName, systemImage: "desktopcomputer")
                .widgetAccentable()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(game.title)
                .font(.headline)
                .lineLimit(family == .systemSmall ? 2 : 1)
                .minimumScaleFactor(0.8)
            if let status = game.status {
                Group {
                    if family != .systemSmall, let checked = game.checkedAt {
                        if game.isJustChecked(at: entry.date) {
                            Text("\(status) · just now")
                        } else {
                            // Minutes, hours or days only (never seconds); the system keeps it ticking.
                            Text("\(status) · \(Text(.currentDate, format: .reference(to: checked, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)))")
                        }
                    } else {
                        Text(status)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(intent: ResumeLastGameIntent()) {
                Label("Resume", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The widget's background (`containerBackground` in the extension; drawn by hand in the gallery).
    static var background: some View {
        LinearGradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.02, green: 0.03, blue: 0.08)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
