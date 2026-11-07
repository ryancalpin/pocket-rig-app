/// The deck's tabs, in swipe order.
enum DeckTab: String, CaseIterable, Identifiable, Sendable {
    case gamepad, trackpad, quickMenu, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gamepad: "Gamepad"
        case .trackpad: "Trackpad"
        case .quickMenu: "Menu"
        case .stats: "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .gamepad: "gamecontroller.fill"
        case .trackpad: "hand.point.up.left.fill"
        case .quickMenu: "square.grid.2x2.fill"
        case .stats: "chart.bar.fill"
        }
    }

    /// Swiping across the content flips tabs, except where the content needs drags itself (sticks, trackpad).
    var allowsContentSwipe: Bool {
        switch self {
        case .gamepad, .trackpad: false
        case .quickMenu, .stats: true
        }
    }

    /// The tab before or after `tab` among `tabs`; nil at either end.
    static func neighbor(of tab: DeckTab, in tabs: [DeckTab], forward: Bool) -> DeckTab? {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.first }
        let next = forward ? index + 1 : index - 1
        return tabs.indices.contains(next) ? tabs[next] : nil
    }
}

/// What the deck does when a physical controller comes or goes. The touch gamepad is useless once a
/// controller connects, so the deck moves to the Quick menu; if it moved itself, it moves back when the
/// controller leaves.
struct DeckHandoff: Equatable, Sendable {
    var tab: DeckTab
    /// The deck moved itself to the Quick menu (and the user hasn't picked a tab since).
    var autoSwitched: Bool

    static func afterControllerChange(current: DeckTab, autoSwitched: Bool, hasController: Bool) -> DeckHandoff {
        if hasController {
            return current == .gamepad ? DeckHandoff(tab: .quickMenu, autoSwitched: true)
                                       : DeckHandoff(tab: current, autoSwitched: autoSwitched)
        }
        if autoSwitched, current == .quickMenu { return DeckHandoff(tab: .gamepad, autoSwitched: false) }
        return DeckHandoff(tab: current, autoSwitched: false)
    }
}
