import SwiftUI
import UIKit

struct AppListView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Phase {
        case loading
        case loaded(HostAPI, [HostApp], runningAppID: Int)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var refreshFailed = false
    @State private var didAutoRetry = false
    @State private var pendingQuit: PendingQuit?
    /// Steam games from Pocket Rig Helper; nil until loaded, or when the PC has no Helper.
    @State private var steamGames: [HelperGame]?
    @State private var steamLoadFailed = false
    /// The Steam game being started on the PC right now.
    @State private var playingAppID: Int?
    /// A short line about the last Steam action that didn't work.
    @State private var steamNotice: String?
    @State private var showInstall = false
    /// Set by the install sheet's "Show my PC's screen"; acted on once the sheet has gone.
    @State private var pendingShowPC = false
    /// The Play in progress. Cancelled when the screen goes away so it can never start a stream later.
    @State private var playTask: Task<Void, Never>?
    /// Looking for the Helper runs apart from loading Sunshine's apps, so pulling to refresh never waits on it.
    @State private var helperTask: Task<Void, Never>?
    /// Each library read takes a number; only the newest may store its answer.
    @State private var libraryGeneration = 0

    private struct PendingQuit {
        let app: HostApp
        let runningTitle: String?
        /// Set when the stream is for a Steam game: start that game on the PC first.
        var steamGame: HelperGame?
    }

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var body: some View {
        content
            .navigationTitle(host.name)
            // Runs on first appearance and again when coming back (e.g. from a stream). Once loaded, it
            // refreshes quietly instead of blanking the grid.
            .task(id: attempt) { await load() }
            // While the app is in front and this screen is showing, keep the Steam library fresh:
            // every 5 seconds while a game is downloading, every 30 otherwise.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                if isLoaded { await refreshLibrary() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: LibraryRefresh.interval(for: steamGames))
                    guard !Task.isCancelled else { return }
                    await refreshLibrary()
                }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { cancelPlay() } }
            .onDisappear {
                cancelPlay()
                helperTask?.cancel()
                // Leaving without resuming (back, replaced by pairing): the request dies with the screen.
                model.cancelPendingResume(for: host.serverUniqueID)
            }
            .onChange(of: steamNotice) {
                if let steamNotice { AccessibilityNotification.Announcement(steamNotice).post() }
            }
            // Already showing this PC's list when "Resume last game" ran.
            .onChange(of: model.pendingResume) { resumeIfRequested() }
            .confirmationDialog(
                LaunchDecision.confirmTitle(runningTitle: pendingQuit?.runningTitle),
                isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
                titleVisibility: .visible, presenting: pendingQuit
            ) { pending in
                Button("Quit and Start \(pending.steamGame?.name ?? pending.app.title)", role: .destructive) {
                    if let game = pending.steamGame {
                        startSteamGame(game, desktop: pending.app, quitRunningFirst: true)
                    } else {
                        startStream(pending.app)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Unsaved progress in that game may be lost.")
            }
            .sheet(isPresented: $showInstall, onDismiss: {
                if pendingShowPC {
                    pendingShowPC = false
                    showPCScreen()
                }
            }) {
                InstallGameSheet(pcName: host.name, client: model.helperClient(for: host),
                                 desktopReady: model.helperStatus(for: host).info?.desktopReady != false,
                                 onShowPC: { pendingShowPC = true })
            }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading games…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load games", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .loaded(_, let apps, _) where apps.isEmpty:
            ContentUnavailableView("No games", systemImage: "gamecontroller",
                                   description: Text("Add apps in Sunshine's web page on your PC, then try again."))
        case .loaded(let api, let apps, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if refreshFailed {
                        Label("Couldn't refresh. Showing your last list.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let steamNotice {
                        Label(steamNotice, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }
                    if let note = HelperStatus.problemNote(for: model.helperStatus(for: host),
                                                           needsRepair: model.helperNeedsRepair.contains(host.serverUniqueID)) {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }
                    SteamGamesSection(pcName: host.name, helper: model.helperStatus(for: host), games: steamGames,
                                      loadFailed: steamLoadFailed, playingAppID: playingAppID,
                                      onPlay: play, onInstall: { startInstall() })
                    VStack(alignment: .leading, spacing: 8) {
                        if model.helperStatus(for: host).info != nil {
                            Text("Streaming apps")
                                .font(.title3.bold())
                                .accessibilityAddTraits(.isHeader)
                        }
                        // Cards widen to fit their longest word at big text sizes ("Desktop" was breaking in two).
                        let minimum = CoverGameCard.listMinimumWidth(for: apps.map(\.title), size: typeSize)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16)], spacing: 16) {
                            ForEach(apps) { app in
                                Button { launch(app) } label: {
                                    AppCard(api: api, app: app, titleLines: CoverGameCard.titleLines(for: typeSize))
                                }
                                    .buttonStyle(.plain)
                                    .disabled(playingAppID != nil)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        let hadList = isLoaded
        if !hadList { phase = .loading }
        do {
            let connection = try await model.connect(host)
            let apps = try await connection.api.appList()
            guard !Task.isCancelled else { return }
            phase = .loaded(connection.api, apps, runningAppID: connection.info.currentGameID)
            refreshFailed = false
            autoLaunchIfRequested(apps)
            // A Helper we already know about answers the library right here; looking for one (slow when
            // the PC has none) happens on its own task.
            if model.helperClient(for: host) != nil, await refreshLibrary() {
                steamNotice = nil
            }
            resumeIfRequested()
            discoverHelper(preferredAddress: connection.address)
        } catch HostError.notPaired {
            guard !Task.isCancelled else { return }
            model.cancelPendingResume(for: host.serverUniqueID)
            model.replaceTop(.apps(serverUniqueID: host.serverUniqueID),
                             with: .pair(serverUniqueID: host.serverUniqueID))
        } catch {
            guard !Task.isCancelled else { return }
            if hadList {
                refreshFailed = true
            } else if !didAutoRetry {
                // The first load over a slow link (e.g. Tailscale relay) often just needs a second go.
                didAutoRetry = true
                attempt += 1
            } else {
                phase = .failed(AppModel.message(for: error))
                model.cancelPendingResume(for: host.serverUniqueID)
            }
        }
    }

    /// Looks for the Helper where Sunshine just answered, then reads the Steam library from it. Runs on its
    /// own task; a newer search replaces an older one.
    private func discoverHelper(preferredAddress: String) {
        helperTask?.cancel()
        helperTask = Task {
            let status = await model.refreshHelper(host, preferredAddress: preferredAddress)
            guard !Task.isCancelled else { return }
            if status.can(.library), model.helperClient(for: host) != nil {
                await refreshLibrary()
            } else {
                libraryGeneration += 1
                steamGames = nil
                steamLoadFailed = false
            }
        }
    }

    /// Reads the Steam library from the Helper we already know. Returns true when it got an answer.
    @discardableResult
    private func refreshLibrary() async -> Bool {
        guard model.helperStatus(for: host).can(.library), let client = model.helperClient(for: host) else { return false }
        libraryGeneration += 1
        let generation = libraryGeneration
        do {
            let games = try await client.library()
            guard !Task.isCancelled, generation == libraryGeneration else { return false }
            if steamGames != games { steamGames = games }
            steamLoadFailed = false
            return true
        } catch is CancellationError {
            return false
        } catch {
            // A list already on screen stays; the section explains when there's none.
            if !Task.isCancelled, generation == libraryGeneration { steamLoadFailed = true }
            return false
        }
    }

    /// The install sheet opens even when the PC's desktop isn't ready: it explains why Install is off.
    private func startInstall() {
        steamNotice = nil
        showInstall = true
    }

    private func launch(_ app: HostApp) {
        var running = 0
        var apps: [HostApp] = []
        if case .loaded(_, let loadedApps, let runningAppID) = phase {
            running = runningAppID
            apps = loadedApps
        }
        switch LaunchDecision.decide(runningAppID: running, selectedAppID: app.id) {
        case .start, .resume:
            startStream(app)
        case .confirmQuit:
            pendingQuit = PendingQuit(app: app, runningTitle: apps.first { $0.id == running }?.title)
        }
    }

    /// A Steam game streams through Sunshine's Desktop app, so the usual "quit the running app?" rule
    /// applies to Desktop.
    private func play(_ game: HelperGame) {
        guard case .loaded(_, let apps, let running) = phase else { return }
        let ready = model.helperStatus(for: host).info?.desktopReady != false
        switch SteamPlay.plan(apps: apps, runningAppID: running, desktopReady: ready) {
        case .desktopNotReady:
            steamNotice = SteamPlay.desktopNotReadyMessage
        case .noDesktop:
            steamNotice = SteamPlay.noDesktopMessage
        case .go(let desktop, .start), .go(let desktop, .resume):
            startSteamGame(game, desktop: desktop, quitRunningFirst: false)
        case .go(let desktop, .confirmQuit):
            pendingQuit = PendingQuit(app: desktop, runningTitle: apps.first { $0.id == running }?.title,
                                      steamGame: game)
        }
    }

    /// Order: quit the running app (only when the user said to), ask the Helper to start the game, then
    /// stream the Desktop. Leaving the screen at any point stops the rest.
    private func startSteamGame(_ game: HelperGame, desktop: HostApp, quitRunningFirst: Bool) {
        guard let client = model.helperClient(for: host), playingAppID == nil else { return }
        playingAppID = game.appID
        steamNotice = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        playTask = Task {
            defer { if playingAppID == game.appID { playingAppID = nil } }
            if quitRunningFirst, case .loaded(let api, let apps, _) = phase {
                do {
                    try await api.cancel()
                    phase = .loaded(api, apps, runningAppID: 0)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    steamNotice = AppModel.message(for: error)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            do {
                _ = try await client.play(appID: game.appID)
                guard !Task.isCancelled else { return }
                startStream(desktop, steamGameName: game.name)
            } catch is CancellationError {
                // Left the screen: don't start anything.
            } catch {
                guard !Task.isCancelled else { return }
                steamNotice = HelperError.message(for: error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func cancelPlay() {
        playTask?.cancel()
        playTask = nil
        playingAppID = nil
    }

    /// "Show my PC's screen" after an install: stream the Desktop so the user can click Steam's prompt.
    private func showPCScreen() {
        guard case .loaded(_, let apps, _) = phase else { return }
        guard let desktop = SteamPlay.desktopApp(in: apps) else {
            steamNotice = SteamPlay.noDesktopMessage
            return
        }
        launch(desktop)
    }

    private func startStream(_ app: HostApp, steamGameName: String? = nil) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.openStream(host, appID: app.id, appTitle: app.title, steamGameName: steamGameName)
    }

    /// "Resume last game" brought us here: start that game the usual way (asking first if another is running).
    private func resumeIfRequested() {
        guard case .loaded(_, let apps, _) = phase,
              let pending = model.takePendingResume(for: host.serverUniqueID) else { return }
        if let app = apps.first(where: { $0.id == pending.appID }) {
            launch(app)
        } else {
            steamNotice = "Your last game isn't in \(host.name)'s list anymore."
        }
    }

    private func autoLaunchIfRequested(_ apps: [HostApp]) {
        guard let title = model.pendingAutoLaunchTitle,
              let app = apps.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame })
        else { return }
        model.pendingAutoLaunchTitle = nil
        launch(app)
    }
}

struct AppCard: View {
    let api: HostAPI?
    let app: HostApp
    /// Lines for the title; the cover gives big text sizes a third.
    var titleLines = 2
    @State private var art: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)

            Text(app.title)
                .font(.headline)
                .lineLimit(titleLines, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.title)
        .accessibilityAddTraits(.isButton)
        .task {
            guard art == nil, let api, let data = try? await api.appArt(appID: app.id) else { return }
            art = UIImage(data: data)
        }
    }
}
