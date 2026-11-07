import AVKit
import Observation
import AVFoundation
import os

private let pipLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "pip")

/// Shows the stream's own video layer in a floating window (for waiting in game queues). The stream keeps
/// playing with sound; the stream screen turns the controls, rumble and tilt off while it shows.
/// Not available in the simulator: `init` gives nil there.
@MainActor @Observable final class StreamPictureInPicture {
    private(set) var isActive = false
    @ObservationIgnored var onStart: @MainActor () -> Void = {}
    @ObservationIgnored var onStop: @MainActor (_ restored: Bool) -> Void = { _ in }

    @ObservationIgnored private let controller: AVPictureInPictureController
    @ObservationIgnored private let events: PiPEvents
    @ObservationIgnored private let playback: LivePlayback

    init?(layer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        // The window needs a playback audio session. Same category and mode as the audio player; it
        // activates the session itself when sound starts, so this only gets the category ready.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            pipLog.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
        let playback = LivePlayback()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer,
                                                                playbackDelegate: playback)
        let controller = AVPictureInPictureController(contentSource: source)
        // A live game: no scrubbing, no skip buttons.
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        let events = PiPEvents()
        controller.delegate = events
        self.controller = controller
        self.events = events
        self.playback = playback
        events.owner = self
    }

    /// While allowed (a live stream, the button editor closed), swiping home starts picture in picture.
    /// The system could open the window by itself right now (it is just slower than expected).
    var couldStartAutomatically: Bool {
        controller.isPictureInPicturePossible && controller.canStartPictureInPictureAutomaticallyFromInline
    }

    func setAllowed(_ allowed: Bool) {
        if controller.canStartPictureInPictureAutomaticallyFromInline != allowed {
            controller.canStartPictureInPictureAutomaticallyFromInline = allowed
        }
    }

    /// The Quick menu's tile. Does nothing until the video layer is on screen and playing.
    /// Returns false when the window can't open yet, so the tile can say so.
    @discardableResult func start() -> Bool {
        guard controller.isPictureInPicturePossible else {
            pipLog.info("Picture in picture not possible yet")
            return false
        }
        controller.startPictureInPicture()
        return true
    }

    func stop() {
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
    }

    fileprivate func started() {
        guard !isActive else { return }
        isActive = true
        onStart()
    }

    fileprivate func stopped(restored: Bool) {
        guard isActive else { return }
        isActive = false
        onStop(restored)
    }
}

/// AVKit calls these on the main thread; its protocols just don't say so.
@MainActor private final class PiPEvents: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    weak var owner: StreamPictureInPicture?
    private var restoring = false

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        owner?.started()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        // The stream screen never went anywhere; it is ready as soon as the app is.
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let restored = restoring
        restoring = false
        owner?.stopped(restored: restored)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        pipLog.error("Picture in picture failed: \(String(describing: error), privacy: .public)")
        restoring = false
        owner?.stopped(restored: false)
    }
}

/// A live stream: always playing, no beginning or end.
private final class LivePlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
