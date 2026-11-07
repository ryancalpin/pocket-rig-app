import SwiftUI

/// One third-party component bundled in the app.
struct OpenSourceComponent: Identifiable, Equatable {
    let name: String
    let license: String
    let attribution: String
    let source: URL?
    /// Extra line shown under the entry (the GPL source offer).
    let note: String?
    /// Bundled license file (`Resources/Licenses/<name>.txt`), shown in full.
    let licenseFile: String
    var id: String { name }
}

enum OpenSourceNoticesData {
    /// Pocket Rig itself first, then the third-party components. Read from the license files in the repo: `moonlight-common-c/LICENSE.txt`, `enet/LICENSE`,
    /// `nanors/LICENSE`, and the OpenSSL-Package `LICENSE` (Package.resolved pins 3.6.5000).
    static let components: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "Pocket Rig", license: "GNU GPL version 3",
            attribution: "\u{00A9} 2026 Ryan Calpin.",
            source: URL(string: "https://github.com/ryancalpin/pocket-rig-app"),
            note: "The complete source code for this app is available from the View source link below. "
                + "Its license includes an App Store Distribution Exception, the same one used by moonlight-common-c.",
            licenseFile: "License-PocketRig"),
        OpenSourceComponent(
            name: "moonlight-common-c", license: "GNU GPL version 3",
            attribution: "The Moonlight streaming core, by the Moonlight Game Streaming Project.",
            source: URL(string: "https://github.com/moonlight-stream/moonlight-common-c"),
            note: "The complete source code for this component is available from the View source link below. "
                + "Its license includes an App Store Distribution Exception: in plain words, you may get this app "
                + "from the App Store even though the store's rules differ from the GPL's, because the source is also "
                + "freely available from that link.",
            licenseFile: "License-moonlight-common-c"),
        OpenSourceComponent(
            name: "ENet", license: "MIT",
            attribution: "Copyright (c) 2002-2020 Lee Salzman. Network transport, bundled with moonlight-common-c.",
            source: URL(string: "https://github.com/cgutman/enet"), note: nil,
            licenseFile: "License-ENet"),
        OpenSourceComponent(
            name: "nanors", license: "MIT",
            attribution: "Copyright (c) 2021 Joseph Calderon. Reed-Solomon error recovery, bundled with moonlight-common-c.",
            source: URL(string: "https://github.com/sleepybishop/nanors"), note: nil,
            licenseFile: "License-nanors"),
        OpenSourceComponent(
            name: "OpenSSL", license: "Apache License 2.0",
            attribution: "OpenSSL 3.x binaries, packaged by Marcin Krzyzanowski (OpenSSL-Package). Used for pairing and encryption.",
            source: URL(string: "https://github.com/krzyzanowskim/OpenSSL-Package"), note: nil,
            licenseFile: "License-OpenSSL"),
    ]
}

/// "Open-source notices": every bundled third-party component with its license.
struct OpenSourceNotices: View {
    var body: some View {
        List {
            ForEach(OpenSourceNoticesData.components) { component in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                        Text(component.attribution).font(.callout)
                        if let note = component.note { Text(note).font(.callout) }
                    }
                    .padding(.vertical, 4)
                    NavigationLink(value: AboutRoute.license(component.licenseFile)) {
                        Label("Full license text", systemImage: "doc.plaintext")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    if let source = component.source {
                        Link(destination: source) {
                            Label("View source", systemImage: "arrow.up.right.square")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                } header: {
                    Text(component.name).font(.headline).textCase(nil)
                }
            }
            Section {
                Text("Pocket Rig is free software, and it is built on these open-source projects. Thank you to everyone who made them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Open-source notices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One bundled license file, full text, selectable, scrollable, scaling with Dynamic Type.
struct LicenseTextView: View {
    let title: String
    let resource: String

    static func text(resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The license text couldn't be loaded."
        }
        return contents
    }

    /// Most source lines in one piece, so even a long paragraph stays a drawable height at the biggest text.
    static let maxLinesPerPiece = 6

    /// One drawn piece of the license: a paragraph, or a few lines of a long one.
    struct Piece: Equatable {
        let text: String
        /// The first piece of a paragraph gets the gap above it; later pieces continue the paragraph.
        let startsParagraph: Bool
    }

    /// The text cut at its blank lines, and long paragraphs cut again every few lines. One `Text` holding the
    /// whole GPL grows taller than iOS can draw at accessibility text sizes and shows up blank.
    static func pieces(of text: String) -> [Piece] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { paragraph -> [Piece] in
                let lines = paragraph.components(separatedBy: "\n")
                return stride(from: 0, to: lines.count, by: maxLinesPerPiece).map {
                    Piece(text: lines[$0..<min($0 + maxLinesPerPiece, lines.count)].joined(separator: "\n"),
                          startsParagraph: $0 == 0)
                }
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.pieces(of: Self.text(resource: resource)).enumerated()), id: \.offset) { index, piece in
                    Text(piece.text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, piece.startsParagraph && index > 0 ? 16 : 0)
                }
            }
            .padding()
        }
        .navigationTitle(title.replacingOccurrences(of: "License-", with: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
