import SwiftUI
import WidgetKit

typealias DownloadContent = DownloadActivityAttributes.ContentState

struct DownloadSymbol: View {
    let state: DownloadContent

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(.green)
            .accessibilityHidden(true)
    }
}

/// The minimal island: a ring that fills up.
struct DownloadRing: View {
    let state: DownloadContent

    var body: some View {
        Gauge(value: state.progress) {
            Image(systemName: "arrow.down")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(.green)
        .accessibilityLabel("\(state.name), \(state.percentText)")
    }
}

/// Progress bar plus one line of detail; used on the Lock Screen and in the expanded island.
struct DownloadDetail: View {
    let pcName: String
    let state: DownloadContent
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: state.progress)
                .tint(.green)
            HStack(spacing: 8) {
                Text(isStale ? DownloadActivityAttributes.staleNote : state.statusText)
                Spacer(minLength: 8)
                Text(state.waitingText ?? "On \(pcName)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

struct DownloadLockScreenView: View {
    let pcName: String
    let state: DownloadContent
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DownloadSymbol(state: state).font(.title2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(state.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(state.percentText).font(.headline).monospacedDigit()
                }
                DownloadDetail(pcName: pcName, state: state, isStale: isStale)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}
