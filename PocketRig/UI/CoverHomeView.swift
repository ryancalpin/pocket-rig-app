import SwiftData
import SwiftUI
import UIKit

/// The closed-phone home on the small outer screen: each PC's status, a Resume button (or Wake PC when the
/// PC is off), its games, and live Steam downloads from Pocket Rig Helper. PCs refresh every 30 seconds,
/// downloads every 5. The outer screen can be either shape, so cards sit in a grid that goes one or two
/// columns wide.
struct CoverHomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Host.lastConnectedAt, order: .reverse) private var hosts: [Host]
    @State private var pendingQuit: PendingQuit?
    /// The PC whose running game is being re-checked before a launch.
    @State private var launchingHostID: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct PendingQuit {
        let host: Host
        let app: HostApp
        let runningTitle: String?
    }

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let status: CoverHostStatus
        let api: HostAPI?
        /// Nil for demo entries, which can't open a stream.
        let host: Host?
        /// The wired network card to wake, when the PC is off and one is known.
        let wakeMAC: String?
    }

    private var entries: [Entry] {
        #if DEBUG
        if DebugLaunchOptions.flag("coverDemo") {
            return CoverHostStatus.demo.map {
                Entry(id: $0.name, name: $0.name, status: $0.status, api: nil, host: nil,
                      wakeMAC: HelperDemo.isOn && $0.status == .offline ? HelperDemo.sampleMAC : nil)
            }
        }
        #endif
        return hosts.map { host in
            let status = host.isPaired ? (model.coverStatuses[host.serverUniqueID] ?? .checking) : .needsPairing
            let mac = host.macAddress.flatMap { WakeOnLAN.isValidMAC($0) ? $0 : nil }
            return Entry(id: host.serverUniqueID, name: host.name, status: status,
                         api: model.coverAPIs[host.serverUniqueID], host: host,
                         wakeMAC: WakeCoordinator.canOffer(status: status, macAddress: mac) ? mac : nil)
        }
    }

    /// The PC the downloads card follows: the most recently used one that has the Helper (or, failing that,
    /// the most recently used paired PC). Nil when there's no paired PC at all.
    private var downloadsHost: Host? {
        let paired = hosts.filter(\.isPaired)
        return paired.first(where: { model.helperStatus(for: $0).info != nil }) ?? paired.first
    }

    private var downloadsState: DownloadsCardState? {
        #if DEBUG
        if DebugLaunchOptions.flag("coverDemo") {
            guard HelperDemo.isOn else { return .noHelper }
            return .make(pcName: "Gaming PC", cover: CoverHostStatus.demo[0].status, helper: .present(HelperDemo.info),
                         downloads: HelperDemo.downloads, misses: 0)
        }
        #endif
        guard let host = downloadsHost else { return nil }
        let id = host.serverUniqueID
        return .make(pcName: host.name, cover: model.coverStatuses[id] ?? .checking,
                     helper: model.helperStatus(for: host), downloads: model.helperDownloads[id],
                     misses: model.helperDownloadMisses[id] ?? 0, needsRepair: model.helperNeedsRepair.contains(id))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if entries.isEmpty {
                    ContentUnavailableView("No PCs yet", systemImage: "desktopcomputer",
                                           description: Text("Open your phone to add your gaming PC."))
                        .frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(entries) { entry in hostCard(entry) }
                    if let downloadsState { DownloadsCard(state: downloadsState) }
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        // Polling only runs while the app is in front; leaving stops it, coming back restarts it.
        .task(id: scenePhase) { if scenePhase == .active { await refreshLoop() } }
        .task(id: scenePhase) { if scenePhase == .active { await downloadsLoop() } }
        .onChange(of: scenePhase) { if scenePhase != .active { model.wakes.stopAll() } }
        .onDisappear { model.wakes.stopAll() }
        .confirmationDialog(
            LaunchDecision.confirmTitle(runningTitle: pendingQuit?.runningTitle),
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            titleVisibility: .visible, presenting: pendingQuit
        ) { pending in
            Button("Quit and Start \(pending.app.title)", role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                open(pending.host, appID: pending.app.id, title: pending.app.title)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Unsaved progress in that game may be lost.")
        }
    }

    private func hostCard(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.name, systemImage: "desktopcomputer")
                .font(.headline)
                .lineLimit(1)
            Label(entry.status.text, systemImage: entry.status.symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let running = entry.status.runningAppID {
                Button { launch(entry, appID: running, title: entry.status.runningTitle ?? "game") } label: {
                    Label(entry.status.resumeTitle, systemImage: "play.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .disabled(launchingHostID != nil)
            } else if entry.wakeMAC != nil {
                WakePCButton(id: entry.id, name: entry.name, host: entry.host)
            }
            WakeNotice(id: entry.id)
            if !entry.status.apps.isEmpty {
                let cardWidth = CoverGameCard.width(for: entry.status.apps.map(\.title), size: typeSize)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entry.status.apps) { app in
                            Button { pick(app, on: entry) } label: {
                                AppCard(api: entry.api, app: app, titleLines: CoverGameCard.titleLines(for: typeSize))
                                    .frame(width: cardWidth)
                            }
                            .buttonStyle(PressableCardStyle())
                            .disabled(launchingHostID != nil)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay { if let id = launchingHostID, id == entry.host?.serverUniqueID { ProgressView().controlSize(.large) } }
    }

    private func open(_ host: Host, appID: Int, title: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.openStream(host, appID: appID, appTitle: title)
    }

    /// Re-checks which game is running right now (the card's status can be 30 s old), then decides
    /// exactly like the app list: start, resume, or ask before quitting the running game.
    private func launch(_ entry: Entry, appID: Int, title: String) {
        guard let host = entry.host, launchingHostID == nil else { return }
        launchingHostID = host.serverUniqueID
        Task {
            defer { launchingHostID = nil }
            // If the PC can't be reached, the stream screen shows the real error.
            var running = 0
            var runningTitle: String?
            if case .online(let id, let t, _)? = await refresh(host, checkHelper: false) {
                running = id
                runningTitle = t
            }
            switch LaunchDecision.decide(runningAppID: running, selectedAppID: appID) {
            case .start, .resume:
                open(host, appID: appID, title: title)
            case .confirmQuit:
                pendingQuit = PendingQuit(host: host, app: HostApp(id: appID, title: title, hdrSupported: false),
                                          runningTitle: runningTitle)
            }
        }
    }

    private func pick(_ app: HostApp, on entry: Entry) {
        launch(entry, appID: app.id, title: app.title)
    }

    private func refreshLoop() async {
        #if DEBUG
        if DebugLaunchOptions.flag("coverDemo") { return }
        #endif
        while !Task.isCancelled {
            // One PC at a time: connect() probes addresses and can be slow over Tailscale.
            for host in hosts where host.isPaired {
                await refresh(host, checkHelper: true)
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Downloads move fast, so the list refreshes every 5 seconds, but only for the PC the card shows, and
    /// only while that PC is on.
    private func downloadsLoop() async {
        #if DEBUG
        if DebugLaunchOptions.flag("coverDemo") { return }
        #endif
        while !Task.isCancelled {
            if let host = downloadsHost, model.coverStatuses[host.serverUniqueID]?.isOnline == true {
                await model.refreshDownloads(host)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// See `AppModel.probeHost`.
    @discardableResult
    private func refresh(_ host: Host, checkHelper: Bool) async -> CoverHostStatus? {
        await model.probeHost(host, checkHelper: checkHelper)
    }
}

/// Dims and shrinks a game card slightly while it's pressed.
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// How wide a game card on the cover is, and how many lines its title gets. A fixed width broke words
/// like "Desktop" in two at large text sizes, so the cards on one PC grow to fit their longest word (up to
/// the usual card scaled with the text), and big sizes get a third line.
enum CoverGameCard {
    static let baseWidth: CGFloat = 112

    static func titleLines(for size: DynamicTypeSize) -> Int { size >= .xxLarge ? 3 : 2 }

    /// The inner screen's app list, whose cards start wider.
    static let listBaseWidth: CGFloat = 140
    /// The widest the app list's smallest card may get: it must still fit an iPhone SE's screen.
    static let listMaximumWidth: CGFloat = 320

    /// One width for all of a PC's cards, so the row stays even. `base` is the card at the default size.
    static func width(for titles: [String], size: DynamicTypeSize, base: CGFloat = baseWidth) -> CGFloat {
        let font = titleFont(for: size)
        let longestWord = titles
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { ceil((String($0) as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        // A little room for SwiftUI's own rounding, so a word that just fits isn't wrapped.
        return min(max(base, longestWord + 4), maximumWidth(for: size, base: base))
    }

    /// The smallest card in the app list's grid (cards may grow wider to fill a row).
    static func listMinimumWidth(for titles: [String], size: DynamicTypeSize) -> CGFloat {
        min(width(for: titles, size: size, base: listBaseWidth), listMaximumWidth)
    }

    /// The usual card scaled with the text: a single very long word is shortened rather than a giant card.
    static func maximumWidth(for size: DynamicTypeSize, base: CGFloat = baseWidth) -> CGFloat {
        max(base, UIFontMetrics(forTextStyle: .headline).scaledValue(for: base, compatibleWith: traits(size)))
    }

    /// The card titles' font (SwiftUI `.headline`) at a text size.
    static func titleFont(for size: DynamicTypeSize) -> UIFont {
        UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits(size))
    }

    private static func traits(_ size: DynamicTypeSize) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
    }
}
