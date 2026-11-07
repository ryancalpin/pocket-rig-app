import SwiftUI

/// "Wake PC" for an offline PC, with its progress line. The cover and the PC list both use it, so the
/// rules, haptics and messages are the same everywhere (see `WakeCoordinator`).
struct WakePCButton: View {
    @Environment(AppModel.self) private var model
    let id: String
    let name: String
    /// Nil for demo entries, which have no PC behind them.
    let host: Host?

    var body: some View {
        let waking = model.wakes.isWaking(id)
        Button { model.wakes.start(id: id, host: host, model: model) } label: {
            HStack(spacing: 8) {
                if waking { ProgressView() } else { Image(systemName: "power") }
                Text(waking ? "Waking…" : "Wake PC")
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .disabled(waking)
        .accessibilityHint("Sends a wake-up signal to \(name) over your home network.")
    }
}

/// The line under a PC after Wake PC ("Waking your PC…", or why it didn't work).
struct WakeNotice: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let notice = model.wakes.notices[id] {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
