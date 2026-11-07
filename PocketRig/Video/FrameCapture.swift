import AVFoundation
import CoreImage
import Photos
import UIKit
import os

private let captureLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "screenshot")

enum ScreenshotResult: Equatable, Sendable {
    case saved, noPermission, nothingToSave, failed

    var message: String {
        switch self {
        case .saved: "Saved to Photos"
        case .noPermission: "Pocket Rig can't save to Photos. Allow it in Settings › Pocket Rig › Photos."
        case .nothingToSave: "Nothing on screen to save yet."
        case .failed: "Couldn't save the screenshot. Try again."
        }
    }

    var symbol: String {
        self == .saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

/// Saves the game frame that is on screen (not the buttons over it) to Photos.
@MainActor
enum FrameCapture {
    /// The frame on screen right now; nil before the first frame.
    static func currentImage(from renderer: VideoRenderer) -> UIImage? {
        guard let buffer = renderer.displayLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func saveCurrentFrame(from renderer: VideoRenderer) async -> ScreenshotResult {
        guard let image = currentImage(from: renderer) else { return .nothingToSave }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .noPermission }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .saved
        } catch {
            captureLog.error("Saving screenshot failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
