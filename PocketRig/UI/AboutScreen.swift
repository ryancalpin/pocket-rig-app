import SwiftUI
import StoreKit

enum AboutRoute: Hashable { case notices, license(String) }

/// "About Pocket Rig": version, support links, an optional tip jar and the open-source notices.
struct AboutScreen: View {
    @State private var tips: TipJarModel
    @Environment(\.dismiss) private var dismiss
    /// Shows the App Store purchase sheet in this screen's window.
    @Environment(\.purchase) private var purchase

    static let supportURL = URL(string: "https://ryancalpin.notion.site/calpinlabs")!
    static let privacyURL = URL(string: "https://github.com/ryancalpin/pocket-rig-app/blob/main/PRIVACY.md")!

    @State private var path: [AboutRoute] = []

    init(store: any TipStore = LiveTipStore()) {
        _tips = State(initialValue: TipJarModel(store: store))
        #if DEBUG
        // -pr.openNotices YES / -pr.openLicense <file> jump straight to those pages for screenshots.
        if let file = DebugLaunchOptions.text("openLicense") {
            _path = State(initialValue: [.notices, .license(file)])
        } else if DebugLaunchOptions.flag("openNotices") {
            _path = State(initialValue: [.notices])
        }
        #endif
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    LabeledContent("Version", value: versionText)
                    Link(destination: Self.supportURL) {
                        Label("Support", systemImage: "questionmark.circle").frame(minHeight: 44, alignment: .leading)
                    }
                    Link(destination: Self.privacyURL) {
                        Label("Privacy", systemImage: "hand.raised").frame(minHeight: 44, alignment: .leading)
                    }
                }
                tipSection
                Section {
                    NavigationLink(value: AboutRoute.notices) {
                        Label("Open-source notices", systemImage: "doc.text").frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
            .navigationDestination(for: AboutRoute.self) { route in
                switch route {
                case .notices: OpenSourceNotices()
                case .license(let file): LicenseTextView(title: file, resource: file)
                }
            }
            .navigationTitle("About Pocket Rig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await tips.load() }
        }
    }

    @ViewBuilder private var tipSection: some View {
        Section {
            switch tips.phase {
            case .loading:
                ProgressView("Loading tips…").frame(minHeight: 44)
            case .unavailable:
                Label("Tips aren't available right now.", systemImage: "heart.slash")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
            case .ready(let options):
                ForEach(options) { option in
                    Button { Task { await tips.buy(option) { try await purchase($0) } } } label: {
                        HStack {
                            Text(option.title)
                            Spacer(minLength: 8)
                            if tips.buying == option.id { ProgressView() } else { Text(option.price).foregroundStyle(.secondary) }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(tips.buying != nil)
                }
            }
            if let notice = tips.notice {
                Label(notice, systemImage: "heart.fill").font(.callout)
            }
        } header: {
            Text("Leave a tip")
        } footer: {
            Text("Tips are optional and unlock nothing — Pocket Rig is free.")
        }
    }
}
