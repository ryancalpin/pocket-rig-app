import SwiftUI

/// The controller area: a glass tab strip and the selected tab. Swipe sideways on the strip (or on a tab
/// that doesn't use drags itself) to change tabs.
struct DeckView: View {
    @Bindable var model: DeckModel
    var tabs: [DeckTab] = DeckTab.allCases
    @Environment(\.hapticsStrength) private var hapticsStrength

    private var current: DeckTab { tabs.contains(model.tab) ? model.tab : (tabs.first ?? .gamepad) }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                ViewThatFits(in: .horizontal) {
                    strip(showsTitles: true)
                    strip(showsTitles: false)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // Past this size the icon-only strip would eat the gamepad's room on small phones.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .simultaneousGesture(swipe)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(swipe, including: current.allowsContentSwipe ? .all : .subviews)
        }
        .background(Color.black.opacity(0.92))
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(trigger: model.tab) { _, _ in
            hapticsStrength.tapIntensity == nil ? nil : SensoryFeedback.selection
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                model.swipe(forward: dx < 0, in: tabs)
            }
    }

    private func strip(showsTitles: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                Button { model.select(tab) } label: {
                    tabLabel(tab, showsTitle: showsTitles)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44)
                        .background {
                            if tab == current { Capsule().fill(Color.white.opacity(0.18)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == current ? Color.white : Color.white.opacity(0.7))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == current ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private func tabLabel(_ tab: DeckTab, showsTitle: Bool) -> some View {
        if showsTitle {
            Label(tab.title, systemImage: tab.symbol).labelStyle(.titleAndIcon)
        } else {
            Label(tab.title, systemImage: tab.symbol).labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .gamepad: gamepad
        case .trackpad: TrackpadTab(pointer: model.pointer, isLive: model.isLive)
        case .quickMenu: QuickMenuTab(model: model)
        case .stats: StatsTab(provider: model.statsProvider)
        }
    }

    @ViewBuilder
    private var gamepad: some View {
        if model.hasPhysicalController {
            ControllerConnectedView()
        } else {
            TouchGamepadView(input: model.gamepad, buttons: model.buttons, style: model.style, showsBackdrop: false)
                .allowsHitTesting(model.isLive)
                .opacity(model.isLive ? 1 : 0.4)
                .animation(.easeOut(duration: 0.25), value: model.isLive)
        }
    }
}

/// Shown in place of the touch buttons while a physical controller is connected.
struct ControllerConnectedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("Controller connected")
                .font(.headline)
            Text("Play with your controller. The touch buttons are hidden while it's connected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
