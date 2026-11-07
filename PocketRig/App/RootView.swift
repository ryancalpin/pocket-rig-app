import SwiftData
import SwiftUI
import os

private let startupLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "startup")

struct RootView: View {
    @State private var poseMonitor = PoseMonitor()

    var body: some View {
        content
            .poseTracking(poseMonitor)
            .environment(poseMonitor)
            .overlay(alignment: .top) {
                if DebugLaunchOptions.showPose { PoseOverlay(monitor: poseMonitor) }
            }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if DebugLaunchOptions.flag("widgetGallery") {
            WidgetGalleryScreen()
        } else if DebugLaunchOptions.flag("steamLibraryDemo") {
            SteamLibraryDemoScreen()
        } else if DebugLaunchOptions.flag("gamepadPreview") {
            GamepadPreview()
        } else if DebugLaunchOptions.streamPreview {
            StreamPreviewScreen()
        } else {
            AppRoot()
        }
        #else
        AppRoot()
        #endif
    }
}

/// Builds the app model from the keychain identity, then hosts the navigation stack.
private struct AppRoot: View {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some View {
        if let model {
            NavigationRoot(model: model)
        } else if let startupError {
            ContentUnavailableView("Pocket Rig can't start", systemImage: "exclamationmark.triangle",
                                   description: Text(startupError))
        } else {
            ProgressView()
                .task { await makeModel() }
        }
    }

    private func makeModel() async {
        do {
            // Keychain and key generation can be slow on first launch; keep them off the main thread.
            let identity = try await Task.detached { try ClientIdentity.loadOrCreate() }.value
            let made = AppModel(identity: identity, makeRequester: { address, certPEM in
                HostHTTPClient(address: address, identity: identity,
                               pinnedServerCertDER: certPEM.flatMap { try? PairingCrypto.certificateDER(certPEM: $0) })
            }, makeHelperClient: { address, certPEM in
                #if DEBUG
                if HelperDemo.isOn { return HelperDemo.client() }
                #endif
                guard let der = try? PairingCrypto.certificateDER(certPEM: certPEM),
                      let http = HelperHTTPClient(address: address, identity: identity, pinnedServerCertDER: der) else {
                    return nil
                }
                return HelperClient(requester: http)
            })
            made.downloadActivities = DownloadActivityController(hosting: LiveDownloadActivities())
            model = made
        } catch {
            startupLog.error("Identity setup failed: \(String(describing: error), privacy: .public)")
            startupError = "Couldn't set up this device's pairing key. Close and reopen Pocket Rig to try again."
        }
    }
}

private struct NavigationRoot: View {
    @Bindable var model: AppModel
    @Environment(\.modelContext) private var context
    @Environment(PoseMonitor.self) private var poses
    @Environment(\.scenePhase) private var scenePhase
    /// What the "Can't resume" alert says.
    @State private var resumeProblem: String?

    var body: some View {
        NavigationStack(path: $model.path) {
            HostListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .pair(let id):
                        HostLookup(serverUniqueID: id) { PairingView(host: $0) }
                    case .apps(let id):
                        HostLookup(serverUniqueID: id) { AppListView(host: $0) }
                    case .stream(let id, let appID):
                        HostLookup(serverUniqueID: id) { StreamScreen(host: $0, appID: appID) }
                    }
                }
        }
        // Hidden from VoiceOver while the cover home covers it.
        .accessibilityHidden(poses.pose == .cover && !(model.path.last?.isStream ?? false))
        // Closed phone: the cover home replaces the inner-screen navigation, except while streaming.
        .overlay {
            if poses.pose == .cover, !(model.path.last?.isStream ?? false) {
                CoverHomeView().transition(.opacity)
            }
        }
        .environment(model)
        // "Resume last game" ran in this process, or before the app was opened.
        .onReceive(NotificationCenter.default.publisher(for: .pocketRigResumeRequested)) { _ in checkResumeRequest() }
        .onChange(of: scenePhase, initial: true) { if scenePhase == .active { checkResumeRequest() } }
        .alert("Can't resume", isPresented: Binding(get: { resumeProblem != nil },
                                                    set: { if !$0 { resumeProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resumeProblem ?? "")
        }
        .task { await applyDebugLaunchOptions() }
        // Keeps the download Live Activity current on the open phone; the closed-phone card runs its own check.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await downloadsLoop()
        }
    }

    private func savedHosts() -> [Host] {
        (try? context.fetch(FetchDescriptor<Host>())) ?? []
    }

    private func checkResumeRequest() {
        guard model.sharedStore.takeResumeRequest(now: .now) else { return }
        resumeProblem = model.resumeLastGame(hosts: savedHosts())
    }

    /// Every 10 seconds while a download shows, every 30 otherwise; only PCs whose Helper reports downloads.
    private func downloadsLoop() async {
        while !Task.isCancelled {
            let streaming = model.path.last?.isStream ?? false
            let coverShowsDownloads = poses.pose == .cover && !streaming
            // No Helper traffic while a game is on screen.
            if !coverShowsDownloads && !streaming {
                let hosts = savedHosts().filter { $0.isPaired && model.helperStatus(for: $0).can(.downloads) }
                var ids = Set(hosts.map(\.serverUniqueID))
                #if DEBUG
                if DebugLaunchOptions.flag("downloadActivityDemo") { ids.insert("demo") }
                #endif
                model.downloadActivities.keepOnly(serverUniqueIDs: ids)
                for host in hosts { await model.refreshDownloads(host) }
            }
            try? await Task.sleep(for: model.downloadActivities.isShowing ? .seconds(10) : .seconds(30))
        }
    }

    /// `-pr.host` adds the host and goes straight to pairing or its app list; `-pr.app` then opens that app.
    private func applyDebugLaunchOptions() async {
        #if DEBUG
        // `-pr.resumeRequest YES`: as if "Resume last game" just ran.
        if DebugLaunchOptions.flag("resumeRequest") {
            model.sharedStore.requestResume(at: .now)
            checkResumeRequest()
        }
        // `-pr.downloadActivityDemo YES`: start the Live Activity from the sample downloads.
        if DebugLaunchOptions.flag("downloadActivityDemo") {
            model.downloadActivities.update(serverUniqueID: "demo", pcName: "Gaming PC", downloads: HelperDemo.downloads)
        }
        let options = DebugLaunchOptions.current
        guard let address = options.hostAddress else { return }
        model.pendingAutoLaunchTitle = options.autoLaunchAppTitle
        do {
            let host = try await model.addHost(address: address, context: context)
            if options.reuseTestPairing, !host.isPaired,
               let pem = KeychainStore(service: "com.ryancalpin.pocketrig.tests.live").read("servercert") {
                // If Sunshine no longer accepts it, connect() clears it and routes to pairing.
                host.serverCertPEM = pem
                try context.save()
            }
            model.path = [host.isPaired ? .apps(serverUniqueID: host.serverUniqueID)
                                        : .pair(serverUniqueID: host.serverUniqueID)]
        } catch {
            print("pr.host \(address): \(AppModel.message(for: error))")
        }
        #endif
    }
}

/// Resolves a route's server ID to the saved host.
private struct HostLookup<Content: View>: View {
    @Query private var hosts: [Host]
    private let content: (Host) -> Content

    init(serverUniqueID: String, @ViewBuilder content: @escaping (Host) -> Content) {
        _hosts = Query(filter: #Predicate<Host> { $0.serverUniqueID == serverUniqueID })
        self.content = content
    }

    var body: some View {
        if let host = hosts.first {
            content(host)
        } else {
            ContentUnavailableView("PC not found", systemImage: "desktopcomputer",
                                   description: Text("This PC was removed. Go back and pick another one."))
        }
    }
}
