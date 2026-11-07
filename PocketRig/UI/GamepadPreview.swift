import SwiftUI

#if DEBUG
/// `-pr.gamepadPreview YES`: the built-in layout for the current pose, with no stream.
/// `-pr.style xbox|playStation|nintendo` picks the labels.
struct GamepadPreview: View {
    @Environment(PoseMonitor.self) private var poses
    @State private var input = GamepadInput(sender: NoOpControllerSender())

    private var style: ControllerStyle {
        DebugLaunchOptions.text("style").flatMap(ControllerStyle.init(rawValue:)) ?? .xbox
    }

    var body: some View {
        GeometryReader { geo in
            let pose = poses.pose
            let fold = PoseRegions.fold(poses.foldInWindow, containerOrigin: geo.frame(in: .global).origin)
            let regions = PoseRegions.make(pose: pose, size: geo.size, fold: fold)
            let area = regions.deck ?? regions.game
            ZStack(alignment: .topLeading) {
                Color(white: 0.2)
                TouchGamepadView(input: input, buttons: DefaultLayouts.buttons(for: pose.layoutPose),
                                 style: style, showsBackdrop: regions.deck != nil)
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }
}
#endif
