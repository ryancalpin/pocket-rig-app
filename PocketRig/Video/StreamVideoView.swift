import SwiftUI
import UIKit

struct StreamVideoView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> VideoHostView {
        renderer.displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        return VideoHostView(layer: renderer.displayLayer)
    }

    func updateUIView(_ uiView: VideoHostView, context: Context) {}
}

final class VideoHostView: UIView {
    private let videoLayer: CALayer

    init(layer: CALayer) {
        videoLayer = layer
        super.init(frame: .zero)
        backgroundColor = .black
        self.layer.addSublayer(layer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
