import CoreGraphics
import Testing
@testable import PocketRig

/// On-screen control glyphs grow with the text size but stay inside their control: at accessibility sizes
/// the View/Home/Menu symbols used to spill out of their circles and over each other.
@Suite struct ControlGlyphTests {
    @Test func theDefaultSizeIsUnchanged() {
        // 17 pt body text in the smallest (44 pt) control: the glyph is drawn as before.
        #expect(ControlGlyph.pointSize(scaled: 17, control: CGSize(width: 44, height: 44)) == 17)
    }

    @Test func bigTextIsCappedByTheControlsShorterSide() {
        // Body text at the largest accessibility size is about 53 pt.
        #expect(ControlGlyph.pointSize(scaled: 53, control: CGSize(width: 44, height: 44)) == 22)
        #expect(ControlGlyph.pointSize(scaled: 53, control: CGSize(width: 80, height: 44)) == 22)
        // The editor draws the canvas at about half size.
        #expect(ControlGlyph.pointSize(scaled: 40, control: CGSize(width: 22, height: 22)) == 11)
    }

    @Test func badgesGetASmallerShare() {
        #expect(ControlGlyph.pointSize(scaled: 30, control: CGSize(width: 50, height: 50),
                                       share: ControlGlyph.maxBadgeShare) == 15)
        #expect(ControlGlyph.pointSize(scaled: 11, control: CGSize(width: 50, height: 50),
                                       share: ControlGlyph.maxBadgeShare) == 11)
    }

    @Test func anEmptyControlKeepsTheTextSize() {
        #expect(ControlGlyph.pointSize(scaled: 17, control: .zero) == 17)
    }
}
