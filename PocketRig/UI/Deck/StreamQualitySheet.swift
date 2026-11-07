import SwiftData
import SwiftUI

/// Quick menu › Quality. Saved right away; used the next time the stream connects.
struct StreamQualitySheet: View {
    @Bindable var preferences: StreamPreferences
    let screenMaxFPS: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// `-pr.openQuality YES` (DEBUG) opens at full height, so screenshots show every section.
    @State private var detent: PresentationDetent = DebugLaunchOptions.flag("openQuality") ? .large : .medium

    var body: some View {
        NavigationStack {
            Form {
                Section("Sharpness") {
                    Picker("Sharpness", selection: $preferences.resolutionCap) {
                        ForEach(ResolutionCap.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                Section("Smoothness") {
                    Picker("Frame rate", selection: $preferences.fps) {
                        ForEach(StreamPreferences.frameRates(screenMaxFPS: screenMaxFPS), id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                }
                Section {
                    Picker("Data use", selection: $preferences.bitrateKbps) {
                        ForEach(StreamPreferences.bitrateChoices, id: \.self) { Text(StreamPreferences.bitrateTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                } header: {
                    Text("Data use")
                } footer: {
                    Text("Changes apply the next time the stream connects.")
                }
                Section {
                    Picker("Away from home", selection: $preferences.awayBitrateKbps) {
                        ForEach(StreamPreferences.awayBitrateChoices, id: \.self) {
                            Text(StreamPreferences.awayBitrateTitle($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                } header: {
                    Text("Away from home")
                } footer: {
                    Text("Used on mobile data, in Low Data Mode and over Tailscale. It uses \(awayUse).")
                }
                Section {
                    Toggle("Overheat protection", isOn: $preferences.heatProtection)
                } footer: {
                    Text("When your phone gets hot, the picture gets a little softer for a while, then goes back to normal.")
                }
            }
            .pickerStyle(.inline)
            .navigationTitle("Stream quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        // Dark like the rest of the stream screen, so the grey notes stay readable over the game.
        // (preferredColorScheme applies to this sheet's own presentation, not the window behind it.)
        .preferredColorScheme(.dark)
        .onDisappear { try? context.save() }
    }

    /// "about 4.5 GB an hour" for the away choice; "Same as at home" uses the home choice.
    private var awayUse: String {
        let kbps = preferences.awayBitrateKbps == 0 ? preferences.bitrateKbps : preferences.awayBitrateKbps
        return DataUse.perHourText(kbps: kbps)
    }
}
