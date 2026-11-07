#if DEBUG
import SwiftUI
import WidgetKit

/// `-pr.widgetGallery YES`: the widgets drawn inside the app, at their real sizes, for screenshots.
struct WidgetGalleryScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Small widget") {
                    HStack(spacing: 16) {
                        widget(.sample, .systemSmall, width: 170)
                        widget(.empty, .systemSmall, width: 170)
                    }
                }
                section("Medium widget") {
                    widget(.sample, .systemMedium, width: 364)
                }
                section("Control Center button") {
                    Label("Resume game", systemImage: "gamecontroller.fill")
                        .font(.headline)
                        .padding(16)
                        .frame(minHeight: 44)
                        .glassEffect(.regular, in: .capsule)
                }
                if let sample = DownloadActivityPlan.content(for: HelperDemo.downloads) {
                    section("Lock Screen download") {
                        VStack(spacing: 8) {
                            lockScreen(sample, isStale: false)
                            lockScreen(sample, isStale: true)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func lockScreen(_ state: DownloadActivityAttributes.ContentState, isStale: Bool) -> some View {
        DownloadLockScreenView(pcName: "Gaming PC", state: state, isStale: isStale)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.7))
            .clipShape(.rect(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
    }

    private func widget(_ entry: LastGameEntry, _ family: WidgetFamily, width: CGFloat) -> some View {
        LastGameWidgetView(entry: entry, family: family)
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: width)
            .frame(height: 170)
            .background(LastGameWidgetView.background)
            .clipShape(.rect(cornerRadius: 24))
    }
}
#endif
