import SwiftUI
import Testing
import UIKit
@testable import PocketRig

/// The Quick menu's notice sits over the tiles for 2.5 s. At the biggest text sizes on the smallest phone it
/// must stay a short strip, not a block that hides a couple of tiles.
@Suite @MainActor struct QuickMenuNoticeTests {
    /// The longest notice the Quick menu shows today.
    private let longest = "Picture in picture isn't ready yet. Try again in a moment."
    /// An iPhone SE's width, less the notice's 16-point margins.
    private let width: CGFloat = 375 - 32

    private func height(_ message: String, at size: DynamicTypeSize) -> CGFloat {
        let view = QuickMenuNoticeLabel(message: message, symbol: "checkmark.circle.fill")
            .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @Test func staysAShortStripAtTheBiggestTextSizes() {
        let usual = height(longest, at: .xxxLarge)
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            #expect(height(longest, at: size) <= usual + 1, "\(size)")
        }
        #expect(usual <= 110)
    }

    @Test func aSavedReplayFitsInOneOrTwoLines() {
        #expect(height("Saved the last 30 seconds to Photos", at: .accessibility5) <= 110)
    }
}
