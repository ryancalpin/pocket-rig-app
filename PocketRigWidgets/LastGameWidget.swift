import SwiftUI
import WidgetKit

struct LastGameProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastGameEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (LastGameEntry) -> Void) {
        completion(context.isPreview ? .sample : .make(store: .standard(), now: .now))
    }

    /// The app reloads the widget whenever the last game or its PC's status changes; this is a fallback.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LastGameEntry>) -> Void) {
        let entry = LastGameEntry.make(store: .standard(), now: .now)
        // A second entry a minute later flips "just now" to a minute count without waking the app.
        let later = LastGameEntry.make(store: .standard(), now: .now.addingTimeInterval(LastGameEntry.justNowAge + 1))
        completion(Timeline(entries: [entry, later], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct LastGameWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PocketRigShared.lastGameWidgetKind, provider: LastGameProvider()) { entry in
            LastGameWidgetContainer(entry: entry)
        }
        .configurationDisplayName("Last game")
        .description("Your last game and its PC, with a button to jump back in.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct LastGameWidgetContainer: View {
    let entry: LastGameEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        LastGameWidgetView(entry: entry, family: family)
            .foregroundStyle(.white)
            .containerBackground(for: .widget) { LastGameWidgetView.background }
    }
}
