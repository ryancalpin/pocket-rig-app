import CoreGraphics
import Testing
@testable import PocketRig

@Suite struct StreamingPoseTests {
    private let wide = CGSize(width: 678, height: 466)
    private let tall = CGSize(width: 466, height: 678)

    @Test func closedPhoneThatIsWideStreamsSideways() {
        #expect(Pose.cover.streamingPose(in: wide) == .sideways)
        #expect(Pose.cover.streamingPose(in: wide).layoutPose == .sideways)
    }

    @Test func closedPhoneThatIsTallKeepsItsPose() {
        #expect(Pose.cover.streamingPose(in: tall) == .cover)
        #expect(Pose.cover.streamingPose(in: CGSize(width: 500, height: 500)) == .cover)
    }

    @Test func otherPosesNeverChange() {
        for pose in Pose.allCases where pose != .cover {
            #expect(pose.streamingPose(in: wide) == pose)
            #expect(pose.streamingPose(in: tall) == pose)
        }
    }

    @Test func wideClosedScreenGetsAFullScreenPicture() {
        let regions = PoseRegions.make(pose: Pose.cover.streamingPose(in: wide), size: wide, fold: nil)
        #expect(regions.game.size == wide)
        #expect(regions.deck == nil)
    }
}
