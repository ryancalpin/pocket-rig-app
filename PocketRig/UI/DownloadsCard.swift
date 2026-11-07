import SwiftUI

/// What the closed-phone Downloads card says.
enum DownloadsCardState: Equatable {
    case checking
    case pcOffline(pc: String)
    case needsPairing(pc: String)
    case needsAppUpdate(pc: String)
    case noHelper
    case steamMissing(pc: String)
    case steamNotSetUp(pc: String)
    case unavailable(pc: String)
    case idle(pc: String)
    case active([HelperDownload])

    /// The PC first (it must be on), then the Helper, then Steam, then the list itself. One missed check
    /// keeps showing the last list; "can't check" needs two misses in a row, or no list to show.
    static func make(pcName: String, cover: CoverHostStatus, helper: HelperStatus,
                     downloads: [HelperDownload]?, misses: Int, needsRepair: Bool = false) -> DownloadsCardState {
        if cover == .checking { return .checking }
        if cover == .needsPairing { return .needsPairing(pc: pcName) }
        guard cover.isOnline else { return .pcOffline(pc: pcName) }
        // The Helper's certificate isn't the one this phone paired with: that's a pairing matter.
        if needsRepair { return .needsPairing(pc: pcName) }
        switch helper {
        case .unknown: return .checking
        case .absent: return .noHelper
        case .needsAppUpdate: return .needsAppUpdate(pc: pcName)
        case .present(let info):
            switch info.steam.state {
            case .notInstalled: return .steamMissing(pc: pcName)
            case .notSetUp, .unknown: return .steamNotSetUp(pc: pcName)
            case .ready: break
            }
        }
        if misses >= 2 || (misses >= 1 && downloads == nil) { return .unavailable(pc: pcName) }
        guard let downloads else { return .checking }
        return downloads.isEmpty ? .idle(pc: pcName) : .active(downloads)
    }

    var headline: String {
        switch self {
        case .checking: "Checking downloads…"
        case .pcOffline(let pc): "Can't reach \(pc)"
        case .needsPairing(let pc): "Pair \(pc) again"
        case .needsAppUpdate: "Update Pocket Rig"
        case .noHelper: "Needs Pocket Rig Helper"
        case .steamMissing: "Steam isn't installed"
        case .steamNotSetUp: "Steam isn't set up yet"
        case .unavailable: "Can't check downloads"
        case .idle: "Nothing downloading"
        case .active(let list): list.count == 1 ? "1 game" : "\(list.count) games"
        }
    }

    var message: String? {
        switch self {
        case .checking, .active: nil
        case .pcOffline: "Downloads show up here when it's on."
        case .needsPairing: "Open your phone and pair this PC again to see downloads here."
        case .needsAppUpdate: "Update Pocket Rig to use this PC's Helper."
        case .noHelper: "Install Pocket Rig Helper on your PC to see game downloads here."
        case .steamMissing(let pc): "Install Steam on \(pc) to see downloads here."
        case .steamNotSetUp(let pc): "Sign in to Steam on \(pc) once. Downloads show up here after that."
        case .unavailable(let pc): "\(pc) didn't answer just now. Pocket Rig keeps trying."
        case .idle(let pc): "Games you install on \(pc) show their progress here."
        }
    }
}

/// The closed-phone Downloads card: up to three games with progress bars, or one plain status line.
struct DownloadsCard: View {
    let state: DownloadsCardState

    private static let maxRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Downloads", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch state {
            case .active(let downloads):
                ForEach(downloads.prefix(Self.maxRows)) { DownloadRow(download: $0) }
                if downloads.count > Self.maxRows {
                    Text("+\(downloads.count - Self.maxRows) more waiting")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(state.headline).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.headline).font(.subheadline.weight(.semibold))
                    if let message = state.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.smooth, value: state)
    }
}

/// One download: wide Steam art, the name, a progress bar, and a short status line.
struct DownloadRow: View {
    let download: HelperDownload
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledArtWidth = 96.0
    /// Art grows with text size but stops at 144 so the biggest text sizes don't make it huge.
    private var artWidth: CGFloat { min(scaledArtWidth, 144) }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                  : AnyLayout(HStackLayout(spacing: 12))
        layout {
            SteamArtImage(urls: [download.headerURL].compactMap { $0 })
                .frame(width: artWidth, height: artWidth * 215 / 460)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(download.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                ProgressView(value: download.progress)
                Text(download.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(download.name)
        .accessibilityValue(download.accessibilityValue)
    }
}

/// Steam art from the CDN: tries each URL in turn (some games have no tall art), then a symbol.
struct SteamArtImage: View {
    let urls: [URL]
    @State private var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                AsyncImage(url: urls[index]) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder.onAppear { index += 1 }
                    default:
                        placeholder.overlay { ProgressView() }
                    }
                }
                .id(urls[index])
            } else {
                placeholder
            }
        }
        .onChange(of: urls) { index = 0 }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}
