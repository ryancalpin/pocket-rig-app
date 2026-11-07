import CoreGraphics
import Foundation
import Testing
@testable import PocketRig

@Suite struct GamepadLayoutTests {
    private let area = CGSize(width: 400, height: 400)

    private func button(_ kind: ControlKind, _ rect: CGRect, in size: CGSize? = nil) -> ControlButton {
        ControlButton(kind: kind, frame: NormalizedRect(rect, in: size ?? area))
    }

    @Test func hiddenButtonsAreLeftOut() {
        var buttons = DefaultLayouts.buttons(for: .upright)
        buttons[0].isHidden = true
        #expect(ControlPlacement.visible(buttons, in: DefaultLayouts.referenceSize(for: .upright)).count == 15)
    }

    @Test func aTinyStickGrowsAroundItsCentre() {
        let rect = ControlPlacement.place(button(.leftStick, CGRect(x: 100, y: 100, width: 50, height: 50)), in: area)
        #expect(rect == CGRect(x: 77, y: 77, width: 96, height: 96))
    }

    @Test func growingNeverPushesOffScreen() {
        // Kept on screen, and the edge inset away from the edge rather than flush against it.
        let rect = ControlPlacement.place(button(.leftStick, CGRect(x: 0, y: 0, width: 50, height: 50)), in: area)
        let inset = ControlPlacement.edgeInset
        #expect(rect == CGRect(x: inset, y: inset, width: 96, height: 96))
    }

    @Test func touchingButtonsArePushedToTheMinimumGap() {
        let a = CGRect(x: 100, y: 100, width: 44, height: 44), b = CGRect(x: 144, y: 100, width: 44, height: 44)
        let out = ControlPlacement.separated([a, b], in: area)
        #expect(abs(out[1].minX - out[0].maxX - ControlPlacement.minimumGap) < 0.01)
        #expect(out[0].minY == 100 && out[1].minY == 100)
    }

    @Test func buttonsAlreadyFarEnoughApartStayPut() {
        let a = CGRect(x: 100, y: 100, width: 44, height: 44), b = CGRect(x: 152, y: 100, width: 44, height: 44)
        #expect(ControlPlacement.separated([a, b], in: area) == [a, b])
    }

    @Test func smallDecksGetTheCompactUprightLayout() {
        let se = CGSize(width: 375, height: 396)
        #expect(DefaultLayouts.adapted(DefaultLayouts.buttons(for: .upright), to: se) == DefaultLayouts.compactUpright)
        // Big decks, other poses and customised layouts are drawn as they are.
        let duo = CGSize(width: 669, height: 574)
        #expect(DefaultLayouts.adapted(DefaultLayouts.buttons(for: .upright), to: duo) == DefaultLayouts.buttons(for: .upright))
        #expect(DefaultLayouts.adapted(DefaultLayouts.buttons(for: .laptop), to: se) == DefaultLayouts.buttons(for: .laptop))
        var custom = DefaultLayouts.buttons(for: .upright)
        custom[0].opacity = 0.5
        #expect(DefaultLayouts.adapted(custom, to: se) == custom)
        // Same controls and IDs, so presses and resets line up.
        #expect(Set(DefaultLayouts.compactUpright.map(\.id)) == Set(DefaultLayouts.buttons(for: .upright).map(\.id)))
    }

    @Test func roundControlsStaySquare() {
        let wide = CGSize(width: 400, height: 200)
        let rect = ControlPlacement.place(button(.faceSouth, CGRect(x: 40, y: 20, width: 80, height: 60), in: wide), in: wide)
        #expect(rect.width == rect.height)
        #expect(rect.width == 60)
    }

    @Test func shoulderButtonsKeepTheirShape() {
        let rect = ControlPlacement.place(button(.leftBumper, CGRect(x: 10, y: 10, width: 80, height: 44)), in: area)
        #expect(rect.size == CGSize(width: 80, height: 44))
    }

    @Test func fadedButtonsStayFindable() {
        var faint = button(.faceSouth, CGRect(x: 10, y: 10, width: 56, height: 56))
        faint.opacity = 0
        #expect(ControlPlacement.visible([faint], in: area).first?.opacity == ControlButton.minimumOpacity)
    }

    @Test(arguments: Pose.layoutPoses)
    func builtInLayoutsAreDrawnAsDesigned(pose: Pose) {
        let reference = DefaultLayouts.referenceSize(for: pose)
        let scaled = CGSize(width: reference.width * 1.25, height: reference.height * 1.1)
        for size in [reference, scaled] {
            for b in DefaultLayouts.buttons(for: pose) {
                let designed = b.frame.rect(in: size)
                let placed = ControlPlacement.place(b, in: size)
                // Round controls keep their centre; compare edges only where nothing was grown or squared.
                let untouched = !b.kind.keepsAspect
                    && designed.width >= ControlPlacement.minimumSide(for: b.kind)
                    && designed.height >= ControlPlacement.minimumSide(for: b.kind)
                if untouched || size == reference {
                    let ok = abs(placed.minX - designed.minX) < 0.5 && abs(placed.maxX - designed.maxX) < 0.5
                        && abs(placed.minY - designed.minY) < 0.5 && abs(placed.maxY - designed.maxY) < 0.5
                    #expect(ok, "\(pose) \(b.kind) at \(size)")
                }
            }
        }
    }

    /// The deck's tab strip sits above the gamepad: 8 pt top padding plus 4 pt of glass around 44 pt tabs
    /// (60 pt). DeckView caps the strip's text size, so at the biggest accessibility sizes it reaches
    /// about 84 pt. Both are checked.
    private static let stripHeights: [CGFloat] = [60, 84]
    /// Landscape safe area on Face ID iPhones: about 62 pt each side and 21 pt at the bottom.
    private static let notchedLandscapeInsets = (sides: CGFloat(62), bottom: CGFloat(21))

    /// (name, pose, screen or deck size, sideways safe area applies) for the shapes the app really draws.
    private static let realDecks: [(String, Pose, CGSize, Bool)] = [
        ("SE upright", .upright, CGSize(width: 375, height: 667), false),
        ("SE sideways", .sideways, CGSize(width: 667, height: 375), false),
        ("17 upright", .upright, CGSize(width: 402, height: 874), false),
        ("17 sideways", .sideways, CGSize(width: 874, height: 402), true),
        ("Pro Max upright", .upright, CGSize(width: 440, height: 956), false),
        ("Pro Max sideways", .sideways, CGSize(width: 956, height: 440), true),
        ("Duo cover", .cover, CGSize(width: 466, height: 678), false),
        ("Duo wide cover", .sideways, CGSize(width: 678, height: 466), false),
        ("Duo upright", .upright, CGSize(width: 669, height: 951), false),
        ("Duo sideways", .sideways, CGSize(width: 951, height: 669), false),
        ("Duo laptop", .laptop, CGSize(width: 669, height: 465), false),
        ("Duo book", .book, CGSize(width: 465, height: 669), false),
    ]

    /// The area the gamepad really gets, the way the app computes it.
    private static func gamepadArea(pose: Pose, screen: CGSize, notched: Bool, strip: CGFloat) -> CGSize {
        switch pose {
        case .sideways:
            // No deck: the buttons float over the whole screen, inside the safe area.
            guard notched else { return screen }
            return CGSize(width: screen.width - 2 * notchedLandscapeInsets.sides,
                          height: screen.height - notchedLandscapeInsets.bottom)
        case .laptop, .book:
            return CGSize(width: screen.width, height: screen.height - strip)   // already deck-sized
        case .upright, .cover:
            let deck = PoseRegions.make(pose: pose, size: screen, fold: nil).deck?.size ?? screen
            return CGSize(width: deck.width, height: deck.height - strip)
        }
    }

    private static let realDeckCases: [String] = realDecks.flatMap { deck in
        stripHeights.map { "\(deck.0) strip \(Int($0))" }
    }

    @Test(arguments: realDeckCases)
    func controlsNeverOverlapOnRealDecks(name: String) throws {
        let deck = try #require(Self.realDecks.first { name.hasPrefix($0.0 + " strip") })
        let strip = try #require(Self.stripHeights.first { name.hasSuffix(" \(Int($0))") })
        let area = Self.gamepadArea(pose: deck.1, screen: deck.2, notched: deck.3, strip: strip)
        let placed = ControlPlacement.visible(DefaultLayouts.buttons(for: deck.1), in: area)
        #expect(placed.count == ControlKind.allCases.count, "\(name): a control went missing")
        let inset = ControlPlacement.edgeInset, gap = ControlPlacement.minimumGap
        let bounds = CGRect(origin: .zero, size: area).insetBy(dx: inset - 0.01, dy: inset - 0.01)
        for p in placed {
            #expect(bounds.contains(p.rect), "\(name) \(p.kind) closer than \(inset) pt to the edge of \(area): \(p.rect)")
            #expect(p.rect.width >= 44 - 0.01 && p.rect.height >= 44 - 0.01, "\(name) \(p.kind) too small: \(p.rect)")
        }
        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] {
                // The gap is the larger of the horizontal and vertical gaps; negative on both means overlap.
                let gapX = max(a.rect.minX - b.rect.maxX, b.rect.minX - a.rect.maxX)
                let gapY = max(a.rect.minY - b.rect.maxY, b.rect.minY - a.rect.maxY)
                #expect(max(gapX, gapY) >= gap - 0.01,
                        "\(name) \(a.kind) and \(b.kind) only \(max(gapX, gapY)) pt apart: \(a.rect) \(b.rect)")
            }
        }
    }
}
