import CoreGraphics
import Testing
@testable import PocketRig

@Suite struct PoseClassifierTests {
    private func pose(_ w: CGFloat, _ h: CGFloat, fold: CGRect? = nil, hinge: Bool = true) -> Pose {
        PoseClassifier.classify(PoseInput(windowSize: CGSize(width: w, height: h), fold: fold, hasHinge: hinge))
    }

    @Test func coverScreenIsClosed() {
        #expect(pose(466, 678) == .cover)
        #expect(pose(678, 466) == .cover)
        // Its squat shape gives it away even before iOS reports a hinge.
        #expect(pose(466, 678, hinge: false) == .cover)
    }

    @Test func horizontalFoldIsHalfFolded() {
        #expect(pose(669, 951, fold: CGRect(x: 0, y: 465, width: 669, height: 21)) == .laptop)
        // A fold reported as a zero-height line still counts.
        #expect(pose(669, 951, fold: CGRect(x: 0, y: 475, width: 669, height: 0)) == .laptop)
    }

    @Test func verticalFoldIsBook() {
        #expect(pose(951, 669, fold: CGRect(x: 465, y: 0, width: 21, height: 669)) == .book)
    }

    @Test func openInnerScreenFollowsRotation() {
        #expect(pose(669, 951) == .upright)
        #expect(pose(951, 669) == .sideways)
    }

    @Test func regularIPhonesUseUprightAndSideways() {
        #expect(pose(402, 874, hinge: false) == .upright)
        #expect(pose(874, 402, hinge: false) == .sideways)
        #expect(pose(375, 667, hinge: false) == .upright)   // iPhone SE, the squattest regular iPhone
    }

    @Test func noWindowYetIsUpright() {
        #expect(pose(0, 0) == .upright)
    }

    @Test func coverBorrowsTheHalfFoldedLayout() {
        #expect(Pose.cover.layoutPose == .laptop)
        #expect(Pose.layoutPoses == [.laptop, .book, .upright, .sideways])
        #expect(Pose.laptop.isFolded && Pose.book.isFolded && !Pose.upright.isFolded)
    }
}

@Suite struct PoseRegionsTests {
    @Test func halfFoldedSplitsAtTheFold() {
        let r = PoseRegions.make(pose: .laptop, size: CGSize(width: 669, height: 951),
                                 fold: CGRect(x: 0, y: 465, width: 669, height: 21))
        #expect(r.game == CGRect(x: 0, y: 0, width: 669, height: 465))
        #expect(r.deck == CGRect(x: 0, y: 486, width: 669, height: 465))
    }

    @Test func bookPutsTheGameOnTheLeftHalf() {
        let r = PoseRegions.make(pose: .book, size: CGSize(width: 951, height: 669),
                                 fold: CGRect(x: 465, y: 0, width: 21, height: 669))
        #expect(r.game == CGRect(x: 0, y: 0, width: 465, height: 669))
        #expect(r.deck == CGRect(x: 486, y: 0, width: 465, height: 669))
    }

    @Test func uprightGivesTheGameTheTopThird() {
        let r = PoseRegions.make(pose: .upright, size: CGSize(width: 669, height: 951), fold: nil)
        #expect(r.game == CGRect(x: 0, y: 0, width: 669, height: 317))
        #expect(r.deck == CGRect(x: 0, y: 317, width: 669, height: 634))
    }

    @Test func narrowIPhoneCapsTheGameAt16by9() {
        let r = PoseRegions.make(pose: .upright, size: CGSize(width: 402, height: 874), fold: nil)
        #expect(r.game.height == 226)
    }

    @Test func sidewaysIsFullScreenWithNoDeck() {
        let r = PoseRegions.make(pose: .sideways, size: CGSize(width: 951, height: 669), fold: nil)
        #expect(r.game == CGRect(x: 0, y: 0, width: 951, height: 669))
        #expect(r.deck == nil)
    }

    @Test func aFoldOutsideTheWindowNeverGivesANegativeFrame() {
        let size = CGSize(width: 669, height: 465)
        let laptop = PoseRegions.make(pose: .laptop, size: size, fold: CGRect(x: 0, y: 900, width: 669, height: 21))
        #expect(laptop.game.height == 465)
        #expect(laptop.deck?.height == 0)
        let above = PoseRegions.make(pose: .laptop, size: size, fold: CGRect(x: 0, y: -40, width: 669, height: 21))
        #expect(above.game.height == 0)
        #expect(above.deck.map { $0.minY >= 0 && $0.height >= 0 && $0.maxY <= 465 } == true)
        let book = PoseRegions.make(pose: .book, size: CGSize(width: 465, height: 669),
                                    fold: CGRect(x: 700, y: 0, width: 21, height: 669))
        #expect(book.game.width == 465)
        #expect(book.deck?.width == 0)
    }

    @Test func foldMovesIntoTheContainersCoordinates() {
        let fold = PoseRegions.fold(CGRect(x: 0, y: 465, width: 669, height: 21), containerOrigin: CGPoint(x: 0, y: 20))
        #expect(fold == CGRect(x: 0, y: 445, width: 669, height: 21))
        #expect(PoseRegions.fold(nil, containerOrigin: .zero) == nil)
    }
}
