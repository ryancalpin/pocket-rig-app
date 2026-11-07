import Observation
import SwiftUI

/// A short line along the bottom of the game picture: overheat protection or the mobile-data warning.
struct StreamBanner: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
    let symbol: String

    static func heat(from old: HeatStep, to new: HeatStep) -> StreamBanner? {
        HeatStep.notice(from: old, to: new).map {
            StreamBanner(message: $0, symbol: new == .normal ? "thermometer.medium" : "thermometer.high")
        }
    }

    static func dataWarning(kbps: Int) -> StreamBanner {
        StreamBanner(message: DataUse.warning(kbps: kbps), symbol: "antenna.radiowaves.left.and.right")
    }
}

/// Shows one banner at a time and hides it after a few seconds.
@MainActor @Observable final class StreamBannerModel {
    static let defaultDuration: Duration = .seconds(6)

    private(set) var current: StreamBanner?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var waiting: [(banner: StreamBanner, duration: Duration)] = []

    func show(_ banner: StreamBanner, for duration: Duration = StreamBannerModel.defaultDuration) {
        hideTask?.cancel()
        AccessibilityNotification.Announcement(banner.message).post()
        withAnimation { current = banner }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            withAnimation { self.current = nil }
            if !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                self.show(next.banner, for: next.duration)
            }
        }
    }

    /// Shows the banner after the current one has had its time, so neither note is lost.
    func showAfterCurrent(_ banner: StreamBanner, for duration: Duration = StreamBannerModel.defaultDuration) {
        if current == nil { show(banner, for: duration) } else { waiting.append((banner, duration)) }
    }

    func clear() {
        hideTask?.cancel()
        waiting.removeAll()
        current = nil
    }
}

/// Place with `.overlay(alignment: .bottom)` on the game picture. The bottom is clear; the close button owns the top.
struct StreamBannerOverlay: View {
    let model: StreamBannerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let banner = model.current {
            Label(banner.message, systemImage: banner.symbol)
                .font(.subheadline.weight(.semibold))
                // A short-lived note: very large text stays readable without covering the whole picture.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                // A note only: taps go through to the on-picture buttons underneath.
                .allowsHitTesting(false)
                .id(banner.id)
        }
    }
}
