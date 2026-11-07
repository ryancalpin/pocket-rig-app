import SwiftUI
import Testing
import UIKit
@testable import PocketRig

/// The cover's game cards: at any text size, no word in a title is broken in two, and short titles aren't cut off.
@Suite @MainActor struct CoverGameCardTests {
    private let titles = ["Desktop", "Hades II", "Steam Big Picture"]
    private let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]

    private func textWidth(_ text: String, _ font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @Test func noWordIsBrokenInTwo() {
        for size in sizes {
            let font = CoverGameCard.titleFont(for: size)
            let width = CoverGameCard.width(for: titles, size: size)
            for word in titles.flatMap({ $0.split(separator: " ") }) {
                #expect(textWidth(String(word), font) <= width, "\(word) at \(size)")
            }
        }
    }

    @Test func theTitlesFitTheirLines() {
        for size in sizes {
            let font = CoverGameCard.titleFont(for: size)
            let width = CoverGameCard.width(for: titles, size: size)
            let lines = CoverGameCard.titleLines(for: size)
            for title in titles {
                let height = (title as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil).height
                // Whole lines; the measured height carries a little line spacing.
                #expect(Int((height / font.lineHeight).rounded()) <= lines, "\(title) at \(size)")
            }
        }
    }

    @Test func theDefaultSizeKeepsTheUsualCard() {
        #expect(CoverGameCard.width(for: titles, size: .large) == CoverGameCard.baseWidth)
    }

    @Test func oneVeryLongWordDoesNotMakeAGiantCard() {
        let width = CoverGameCard.width(for: ["Supercalifragilisticexpialidocious"], size: .accessibility5)
        #expect(width <= CoverGameCard.maximumWidth(for: .accessibility5))
    }
}

/// The inner screen's app list uses the same sizing with a wider card: its grid used a fixed 140-point
/// minimum, so "Desktop" broke as "Desk-top" and "Steam Big Picture" was cut off at large text sizes.
@Suite @MainActor struct AppListCardTests {
    private let titles = ["Desktop", "Steam Big Picture"]

    @Test func noWordIsBrokenInTwoAndTheCardStillFitsAnSE() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
            let font = CoverGameCard.titleFont(for: size)
            let width = CoverGameCard.listMinimumWidth(for: titles, size: size)
            for word in titles.flatMap({ $0.split(separator: " ") }) {
                let wordWidth = ceil((String(word) as NSString).size(withAttributes: [.font: font]).width)
                #expect(wordWidth <= width, "\(word) at \(size)")
            }
            #expect(width <= 375 - 32, "\(size)")
        }
    }

    @Test func theDefaultSizeKeepsTheUsualGrid() {
        #expect(CoverGameCard.listMinimumWidth(for: titles, size: .large) == CoverGameCard.listBaseWidth)
    }
}
