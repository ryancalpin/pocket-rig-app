import SwiftUI

/// "Steam games" above the streaming apps: the PC's installed and downloading Steam games, with an
/// Install button. Shows a plain notice instead when Steam on the PC isn't ready, and nothing at all
/// when the PC has no Pocket Rig Helper.
struct SteamGamesSection: View {
    let pcName: String
    let helper: HelperStatus
    let games: [HelperGame]?
    let loadFailed: Bool
    let playingAppID: Int?
    let onPlay: (HelperGame) -> Void
    let onInstall: () -> Void

    init(pcName: String, helper: HelperStatus, games: [HelperGame]?, loadFailed: Bool, playingAppID: Int?,
         onPlay: @escaping (HelperGame) -> Void, onInstall: @escaping () -> Void) {
        self.pcName = pcName
        self.helper = helper
        self.games = games
        self.loadFailed = loadFailed
        self.playingAppID = playingAppID
        self.onPlay = onPlay
        self.onInstall = onInstall
    }

    nonisolated static func notice(for info: HelperInfo, pcName: String) -> (title: String, message: String)? {
        switch info.steam.state {
        case .ready: nil
        case .notInstalled: ("Steam isn't installed", "Install Steam on \(pcName) to see your Steam games here.")
        case .notSetUp, .unknown: ("Steam isn't set up yet", "Sign in to Steam on \(pcName) once to see your Steam games here.")
        }
    }

    var body: some View {
        if helper.steamReady, helper.can(.library) {
            VStack(alignment: .leading, spacing: 8) {
                header
                list
            }
        } else if let info = helper.info, let notice = Self.notice(for: info, pcName: pcName) {
            VStack(alignment: .leading, spacing: 8) {
                Label(notice.title, systemImage: "info.circle")
                    .font(.headline)
                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                title
                Spacer()
                installButton
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                installButton
            }
        }
    }

    private var title: some View {
        Text("Steam games")
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var installButton: some View {
        if helper.can(.install) {
            Button(action: onInstall) {
                Label("Install a game", systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(playingAppID != nil)
            .accessibilityHint("Install a game on \(pcName) from a Steam link.")
        }
    }

    /// A lazy row is as tall as its first card, so when any game is still downloading every card keeps
    /// room for the two status lines.
    private var anyBusy: Bool { (games ?? []).contains { $0.state != .installed || $0.updatePending } }

    @ViewBuilder private var list: some View {
        if let games {
            if games.isEmpty {
                Text("No Steam games are installed on \(pcName) yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(SteamPlay.sorted(games)) { game in
                            Button {
                                if game.state == .installed, playingAppID == nil { onPlay(game) }
                            } label: {
                                SteamGameCard(game: game, isStarting: playingAppID == game.appID, reservesStatusRoom: anyBusy)
                            }
                            .buttonStyle(.plain)
                            // A game that isn't installed can't be played: no button, just its status.
                            .disabled(game.state != .installed)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        } else if loadFailed {
            Text("Couldn't load Steam games. Pull down to try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ProgressView("Loading Steam games…")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One Steam game: tall art, the name, and progress when it's still downloading.
struct SteamGameCard: View {
    let game: HelperGame
    let isStarting: Bool
    var reservesStatusRoom = false
    @ScaledMetric(relativeTo: .headline) private var scaledWidth = 120.0
    /// Grows with the text, but not past a card that still fits two on a small screen.
    private var width: Double { min(scaledWidth, 168) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SteamArtImage(urls: game.artURLs)
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    if game.state != .installed {
                        ProgressView(value: game.progress)
                            .padding(8)
                            .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                            .padding(8)
                    }
                }
                .overlay {
                    if isStarting { ProgressView().controlSize(.large) }
                }
                .opacity(game.state == .installed ? 1 : 0.7)
            Text(game.name)
                .font(.headline)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if game.state != .installed || game.updatePending || reservesStatusRoom {
                Text(game.state == .installed && !game.updatePending ? " " : game.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.name)
        .accessibilityValue(game.state == .installed ? (game.updatePending ? game.statusText : "") : "\(Int((game.progress * 100).rounded())) percent, \(game.statusText)")
        .accessibilityHint(game.state == .installed ? "Starts the game on your PC and shows it here." : game.statusText)
        .accessibilityAddTraits(game.state == .installed ? .isButton : [])
    }
}
