#if DEBUG
import SwiftUI

/// `-pr.steamLibraryDemo YES` (with `-pr.helperDemo YES`): the app list's Steam section with sample games,
/// for screenshots without a PC. `-pr.openInstallSheet YES` opens the install sheet;
/// `-pr.installDemoText <text>` pre-fills it.
struct SteamLibraryDemoScreen: View {
    @State private var showInstall = DebugLaunchOptions.flag("openInstallSheet")
    @Environment(\.dynamicTypeSize) private var typeSize
    private let apps = [HostApp(id: 1, title: "Desktop", hdrSupported: false),
                        HostApp(id: 2, title: "Steam Big Picture", hdrSupported: false)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SteamGamesSection(pcName: "Gaming PC", helper: .present(HelperDemo.info),
                                      games: HelperDemo.steamNotSetUp ? nil : HelperDemo.games, loadFailed: false,
                                      playingAppID: nil, onPlay: { _ in }, onInstall: { showInstall = true })
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Streaming apps")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        let minimum = CoverGameCard.listMinimumWidth(for: apps.map(\.title), size: typeSize)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16)], spacing: 16) {
                            ForEach(apps) {
                                AppCard(api: nil, app: $0, titleLines: CoverGameCard.titleLines(for: typeSize))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Gaming PC")
        }
        .sheet(isPresented: $showInstall) {
            InstallGameSheet(pcName: "Gaming PC", client: HelperDemo.client(),
                             initialText: DebugLaunchOptions.text("installDemoText") ?? "", onShowPC: {})
        }
    }
}
#endif
