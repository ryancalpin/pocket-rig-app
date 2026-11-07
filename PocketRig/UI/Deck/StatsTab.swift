import SwiftUI

/// Deck tab: how much delay there is and where it comes from. Refreshes once a second.
struct StatsTab: View {
    let provider: @MainActor () -> StatsSnapshot?
    @State private var snapshot: StatsSnapshot?

    init(provider: @escaping @MainActor () -> StatsSnapshot?) {
        self.provider = provider
        _snapshot = State(initialValue: provider())
    }

    var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        rows(snapshot)
                        Text("Total delay adds up the PC, the network round trip and this phone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("No numbers yet", systemImage: "chart.bar",
                                       description: Text("Delay and frame rate show up here once the game is on screen."))
            }
        }
        .task {
            while !Task.isCancelled {
                snapshot = provider()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func rows(_ s: StatsSnapshot) -> some View {
        VStack(spacing: 0) {
            row("Total delay", "gauge.with.dots.needle.67percent", StatsText.milliseconds(s.totalMs, frames: s.frames), emphasized: true)
            Divider()
            row("PC", "desktopcomputer", StatsText.pcTime(s.frames))
            Divider()
            row("Network round trip", "network", StatsText.milliseconds(s.rttMs))
            Divider()
            row("Phone", "iphone", StatsText.milliseconds(s.frames.phoneMs, frames: s.frames))
            Divider()
            row("Frame rate", "speedometer", StatsText.framesPerSecond(s.frames))
            Divider()
            row("Connection", s.quality.symbol, s.quality.title)
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func row(_ title: String, _ symbol: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(emphasized ? .headline : .body)
        .lineLimit(2)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
