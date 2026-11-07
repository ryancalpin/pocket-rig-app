import SwiftUI
import UIKit

/// Install a Steam game on the PC from a pasted Steam link or app number.
struct InstallGameSheet: View {
    enum Phase: Equatable {
        case editing
        case sending
        case sent(confirmOnPC: Bool)
        case failed(String)

        /// Editing the link starts over, except while a request is in flight.
        var afterTextChange: Phase { self == .sending ? self : .editing }
        var isSent: Bool { if case .sent = self { true } else { false } }
    }

    let pcName: String
    let client: HelperClient?
    /// False when the Helper says the PC's desktop isn't up yet (Steam can't open a window).
    let desktopReady: Bool
    let onShowPC: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var phase: Phase = .editing
    /// Worked out once per edit, not on every redraw.
    @State private var appID: Int?

    init(pcName: String, client: HelperClient?, initialText: String = "", desktopReady: Bool = true,
         onShowPC: @escaping () -> Void) {
        self.pcName = pcName
        self.client = client
        self.desktopReady = desktopReady
        self.onShowPC = onShowPC
        _text = State(initialValue: initialText)
        _appID = State(initialValue: SteamLink.appID(from: initialText))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Steam link or app number", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(send)
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in text = strings.first ?? "" }
                    }
                    .labelStyle(.titleAndIcon)
                } footer: {
                    Text("In the Steam app or store, open the game, tap Share, and copy the link. Then paste it here.")
                }
                if let appID {
                    Section("Game") {
                        SteamArtImage(urls: [SteamArt.header(appID)])
                            .aspectRatio(460 / 215, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Label("That doesn't look like a Steam game link.", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                statusSection
            }
            .navigationTitle("Install a game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase.isSent {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Install", action: send)
                            .disabled(appID == nil || client == nil || !desktopReady || phase == .sending)
                    }
                }
            }
            .onChange(of: text) {
                appID = SteamLink.appID(from: text)
                phase = phase.afterTextChange
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var statusSection: some View {
        switch phase {
        case .editing:
            if client == nil {
                Section {
                    Label(HelperError.unreachable.message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else if !desktopReady {
                Section {
                    Label(SteamPlay.desktopNotReadyMessage, systemImage: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
        case .sending:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking \(pcName)…")
                }
            }
        case .sent(let confirmOnPC):
            Section {
                Label("Sent to \(pcName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if confirmOnPC {
                    Text("Steam may ask you to confirm on your PC. Open your PC's screen to click Install.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        dismiss()
                        onShowPC()
                    } label: {
                        Label("Show my PC's screen", systemImage: "display")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        guard let appID, let client, desktopReady, phase != .sending else { return }
        phase = .sending
        Task {
            do {
                let reply = try await client.install(appID: appID)
                phase = .sent(confirmOnPC: reply.confirmOnPC ?? false)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                phase = .editing
            } catch {
                phase = .failed(HelperError.message(for: error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
