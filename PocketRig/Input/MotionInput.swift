import CMoonlight
import CoreMotion
import GameController
import UIKit

protocol MotionEventSending: Sendable {
    func send(type: UInt8, _ value: SIMD3<Float>)
}

struct MoonlightMotionSender: MotionEventSending {
    func send(type: UInt8, _ value: SIMD3<Float>) {
        // Hosts without motion support answer LI_ERR_UNSUPPORTED; nothing to do then.
        _ = LiSendControllerMotionEvent(0, type, value.x, value.y, value.z)
    }
}

extension GyroOrientation {
    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }

    /// The active window's orientation (`interfaceOrientation` on the scene is deprecated in iOS 26).
    @MainActor
    static func current() -> GyroOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return GyroOrientation(scene?.effectiveGeometry.interfaceOrientation ?? .portrait)
    }
}

/// Tilt to aim with the phone: reads the phone's gyro while a stream is live and tilt is on, and hands
/// out right-stick positions or mouse moves. Needs no permission prompt.
@MainActor
final class MotionHub {
    static let aimRateHz = 120.0

    var onStick: @MainActor (SIMD2<Float>) -> Void = { _ in }
    var onMouse: @MainActor (Int16, Int16) -> Void = { _, _ in }
    var orientation: @MainActor () -> GyroOrientation = { GyroOrientation.current() }
    private(set) var isRunning = false

    /// Made on first use: SwiftUI may create several hubs while building a view.
    private lazy var manager = CMMotionManager()
    private var settings = FeelSnapshot()
    private var live = false
    private var mouse = GyroMouseAccumulator()
    private var lastTimestamp: TimeInterval?

    func apply(_ settings: FeelSnapshot) {
        let modeChanged = settings.gyroMode != self.settings.gyroMode
        self.settings = settings
        if modeChanged { neutral() }
        update()
    }

    func setLive(_ live: Bool) {
        self.live = live
        update()
    }

    private func update() {
        let wanted = live && settings.gyroMode != .off
        let run = wanted && manager.isDeviceMotionAvailable
        guard run != isRunning else { return }
        isRunning = run
        if run {
            neutral()
            manager.deviceMotionUpdateInterval = 1 / Self.aimRateHz
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion else { return }
                let sample = GyroSample(
                    rotationRate: [motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z],
                    gravity: [motion.gravity.x, motion.gravity.y, motion.gravity.z])
                let timestamp = motion.timestamp
                // Delivered on the main queue.
                MainActor.assumeIsolated { self?.handle(sample, timestamp: timestamp) }
            }
        } else {
            manager.stopDeviceMotionUpdates()
            neutral()
        }
    }

    private func handle(_ sample: GyroSample, timestamp: TimeInterval) {
        // A sample CoreMotion queued before stop() still arrives afterwards; it must not move the stick
        // that stop() just centred.
        guard isRunning else { return }
        let aim = GyroAim.aimRate(sample, orientation: orientation())
        switch settings.gyroMode {
        case .off:
            break
        case .rightStick:
            onStick(GyroStickMapper.stick(aim: aim, sensitivity: settings.gyroSensitivity,
                                          invertY: settings.gyroInvertY))
        case .mouse:
            if let last = lastTimestamp,
               let move = mouse.move(aim: aim, seconds: timestamp - last, sensitivity: settings.gyroSensitivity,
                                     invertY: settings.gyroInvertY) {
                onMouse(move.dx, move.dy)
            }
            lastTimestamp = timestamp
        }
    }

    private func neutral() {
        onStick(.zero)
        mouse.reset()
        lastTimestamp = nil
    }
}

/// A real controller's motion sensors (DualSense, DualShock), sent to the PC only while it asks.
@MainActor
final class ControllerMotionReporter {
    private let sender: any MotionEventSending
    private weak var controller: GCController?
    private var requests = MotionRequests()
    private var lastReport: TimeInterval = 0

    init(sender: any MotionEventSending = MoonlightMotionSender()) {
        self.sender = sender
    }

    var canReport: Bool { controller?.motion?.hasRotationRate == true }

    /// The pad in use changed (nil: none).
    func attach(_ controller: GCController?) {
        guard controller !== self.controller else { return }
        stopSensors()
        self.controller = controller
        requests.reset()
    }

    func hostRequested(type: UInt8, rateHz: UInt16) {
        requests.apply(type: type, rateHz: rateHz)
        guard let motion = controller?.motion else { return }
        guard requests.isActive else {
            stopSensors()
            return
        }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        motion.valueChangedHandler = { [weak self] motion in
            let rate: SIMD3<Double>? = motion.hasRotationRate
                ? [motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z] : nil
            let acceleration: SIMD3<Double> = [motion.acceleration.x, motion.acceleration.y, motion.acceleration.z]
            // GameController calls handlers on the main queue (its default `handlerQueue`).
            MainActor.assumeIsolated { self?.report(rotationRate: rate, acceleration: acceleration) }
        }
    }

    /// The stream stopped or is reconnecting.
    func reset() {
        requests.reset()
        stopSensors()
    }

    private func report(rotationRate: SIMD3<Double>?, acceleration: SIMD3<Double>) {
        let now = ProcessInfo.processInfo.systemUptime
        guard requests.isActive, now - lastReport >= 0.9 / requests.rateHz else { return }
        lastReport = now
        if requests.gyroHz > 0, let rotationRate {
            sender.send(type: UInt8(LI_MOTION_TYPE_GYRO), MotionConversion.gyro(rotationRate))
        }
        if requests.accelHz > 0 {
            sender.send(type: UInt8(LI_MOTION_TYPE_ACCEL), MotionConversion.acceleration(acceleration))
        }
    }

    private func stopSensors() {
        guard let motion = controller?.motion else { return }
        motion.valueChangedHandler = nil
        if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
    }
}
