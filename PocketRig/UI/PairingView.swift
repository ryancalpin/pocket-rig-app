import SwiftUI

struct PairingView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var pin = DebugLaunchOptions.current.pairingPIN ?? PairingService.makePIN()
    @State private var attempt = 0
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: errorMessage == nil ? "lock.shield" : "exclamationmark.triangle")
                    .font(.system(.largeTitle))
                    .imageScale(.large)
                    .foregroundStyle(errorMessage == nil ? Color.accentColor : .orange)
                    .accessibilityHidden(true)
                    .padding(.top, 32)

                if let errorMessage {
                    Text("Pairing didn't work").font(.title2.bold())
                    Text(errorMessage)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try again") { retry() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Text("Enter this PIN in Sunshine on your PC")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text(pin)
                        .font(.largeTitle.monospacedDigit().bold())
                        .kerning(8)
                        .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
                    Text("In Sunshine's web page on your PC, open the PIN tab and type these four digits.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ProgressView("Waiting for your PC…")
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pair \(host.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await runPairing() }
    }

    private func runPairing() async {
        errorMessage = nil
        do {
            try await model.pair(host, pin: pin)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            guard !Task.isCancelled else { return }
            model.finishPairing(serverUniqueID: host.serverUniqueID)
        } catch {
            guard !Task.isCancelled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = AppModel.pairingMessage(for: error)
        }
    }

    private func retry() {
        // A fresh PIN each time; the debug PIN stays fixed so the helper script can keep entering it.
        pin = DebugLaunchOptions.current.pairingPIN ?? PairingService.makePIN()
        attempt += 1
    }
}
