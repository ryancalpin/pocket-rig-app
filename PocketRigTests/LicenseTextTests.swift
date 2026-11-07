import SwiftUI
import Testing
import UIKit
@testable import PocketRig

/// The full license pages. One `Text` holding the whole GPL came out blank at accessibility text sizes,
/// because it grew taller than iOS can draw; each paragraph now gets its own.
@Suite @MainActor struct LicenseTextTests {
    private let files = ["License-PocketRig", "License-moonlight-common-c", "License-ENet", "License-nanors", "License-OpenSSL"]
    /// An iPhone SE's width, less the page's 16-point margins.
    private let width: CGFloat = 375 - 32

    private func height(_ text: String, at size: DynamicTypeSize) -> CGFloat {
        let view = Text(text).font(.footnote.monospaced()).environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @Test func everyBundledLicenseLoads() {
        for file in files {
            #expect(!LicenseTextView.text(resource: file).hasPrefix("The license text couldn't"), "\(file)")
        }
    }

    @Test func paragraphsKeepEveryWordInOrder() {
        for file in files {
            let text = LicenseTextView.text(resource: file)
            let words = { (s: String) in s.split(whereSeparator: \.isWhitespace) }
            #expect(words(LicenseTextView.pieces(of: text).map(\.text).joined(separator: "\n\n")) == words(text), "\(file)")
        }
    }

    @Test func blankLinesSplitAndEmptyPiecesDrop() {
        #expect(LicenseTextView.pieces(of: "One\nline two\n\n\n  Indented\n\n").map(\.text) == ["One\nline two", "  Indented"])
        // A long paragraph is cut every few lines; only its first piece starts a paragraph.
        let long = (1...8).map(String.init).joined(separator: "\n")
        #expect(LicenseTextView.pieces(of: long) == [.init(text: "1\n2\n3\n4\n5\n6", startsParagraph: true),
                                                     .init(text: "7\n8", startsParagraph: false)])
    }

    /// Each piece stays well below the height iOS can draw, even at the biggest text size on the smallest phone.
    /// (The whole GPL in one `Text` drew at the default size, about 11,000 points tall, and failed above it.)
    @Test func everyParagraphStaysDrawableAtTheBiggestTextSize() {
        for file in files {
            let tallest = LicenseTextView.pieces(of: LicenseTextView.text(resource: file))
                .map { height($0.text, at: .accessibility5) }.max() ?? 0
            #expect(tallest > 0, "\(file)")
            #expect(tallest < 4_000, "\(file): \(tallest)")
        }
        // The whole GPL as one block was the failure: far taller than that.
        #expect(height(LicenseTextView.text(resource: "License-moonlight-common-c"), at: .accessibility5) > 10_000)
    }
}
