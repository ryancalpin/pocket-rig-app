import CMoonlight
import Foundation
import GameController
import Testing
@testable import PocketRig

private let degrees = 180 / Double.pi

@Suite struct GyroAimTests {
    private func aim(_ rate: SIMD3<Double>, gravity: SIMD3<Double>, _ o: GyroOrientation = .portrait) -> SIMD2<Double> {
        GyroAim.aimRate(GyroSample(rotationRate: rate, gravity: gravity), orientation: o)
    }

    @Test func turningRightAimsRight() {
        // Held upright in portrait: gravity points down the screen.
        let a = aim([0, -1, 0], gravity: [0, -1, 0])
        #expect(approximately(a.x, degrees))
        #expect(a.y == 0)
    }

    @Test func tippingTheTopBackAimsUp() {
        let a = aim([1, 0, 0], gravity: [0, -1, 0])
        #expect(approximately(a.y, degrees))
        #expect(a.x == 0)
    }

    @Test func turningWorksLyingFlatToo() {
        // Flat on a table (or the Duo's bottom half): "up" is out of the screen.
        let a = aim([0, 0, -1], gravity: [0, 0, -1])
        #expect(approximately(a.x, degrees))
    }

    @Test func sidewaysUsesTheScreensAxes() {
        // Landscape right: the phone's top edge points left.
        let up = aim([0, -1, 0], gravity: [-1, 0, 0], .landscapeRight)
        #expect(approximately(up.y, degrees))
        let right = aim([-1, 0, 0], gravity: [-1, 0, 0], .landscapeRight)
        #expect(approximately(right.x, degrees))
        let left = aim([0, 1, 0], gravity: [1, 0, 0], .landscapeLeft)
        #expect(approximately(left.y, degrees))
    }

    @Test func upsideDownFlipsBoth() {
        let a = aim([-1, 0, 0], gravity: [0, 1, 0], .portraitUpsideDown)
        #expect(approximately(a.y, degrees))
    }

    @Test func withoutGravityTheScreensUpIsUsed() {
        let a = aim([0, -1, 0], gravity: .zero)
        #expect(approximately(a.x, degrees))
    }

    @Test func tinyShakesAreIgnored() {
        #expect(aim([0.01, -0.01, 0], gravity: [0, -1, 0]) == .zero)
    }
}

@Suite struct GyroStickTests {
    @Test func stillMeansCentred() {
        #expect(GyroStickMapper.stick(aim: .zero, sensitivity: 1, invertY: false) == .zero)
    }

    @Test func fullSpeedIsAFullStick() {
        let s = GyroStickMapper.stick(aim: [GyroStickMapper.fullSpeed, 0], sensitivity: 1, invertY: false)
        #expect(approximately(s.x, 1))
        #expect(s.y == 0)
    }

    @Test func slowTurnsGetPastTheGamesDeadZone() {
        let s = GyroStickMapper.stick(aim: [GyroStickMapper.fullSpeed / 2, 0], sensitivity: 1, invertY: false)
        #expect(approximately(s.x, Float(GyroStickMapper.antiDeadZone + 0.5 * (1 - GyroStickMapper.antiDeadZone))))
    }

    @Test func sensitivityAndFlipApply() {
        let fast = GyroStickMapper.stick(aim: [0, GyroStickMapper.fullSpeed / 4], sensitivity: 2, invertY: false)
        let normal = GyroStickMapper.stick(aim: [0, GyroStickMapper.fullSpeed / 4], sensitivity: 1, invertY: false)
        #expect(fast.y > normal.y)
        let flipped = GyroStickMapper.stick(aim: [0, GyroStickMapper.fullSpeed / 4], sensitivity: 1, invertY: true)
        #expect(approximately(flipped.y, -normal.y))
    }

    @Test func wildSwingsStayOnTheStick() {
        let s = GyroStickMapper.stick(aim: [10_000, 10_000], sensitivity: 3, invertY: false)
        #expect(approximately((s.x * s.x + s.y * s.y).squareRoot(), 1))
    }
}

@Suite struct GyroMouseTests {
    @Test func aimSpeedBecomesPixels() {
        var m = GyroMouseAccumulator()
        let move = m.move(aim: [32, 16], seconds: 0.0625, sensitivity: 1, invertY: false)
        #expect(move?.dx == 20)
        #expect(move?.dy == -10)   // aiming up moves the pointer up the screen
    }

    @Test func fractionsCarryOver() {
        var m = GyroMouseAccumulator()
        for _ in 0..<3 { #expect(m.move(aim: [2, 0], seconds: 1.0 / 64, sensitivity: 1, invertY: false) == nil) }
        #expect(m.move(aim: [2, 0], seconds: 1.0 / 64, sensitivity: 1, invertY: false)?.dx == 1)
    }

    @Test func gapsAreNotMotion() {
        var m = GyroMouseAccumulator()
        #expect(m.move(aim: [100, 0], seconds: 0.5, sensitivity: 1, invertY: false) == nil)
        #expect(m.move(aim: [100, 0], seconds: 0, sensitivity: 1, invertY: false) == nil)
    }

    @Test func flipReversesUpAndDown() {
        var m = GyroMouseAccumulator()
        #expect(m.move(aim: [0, 16], seconds: 0.0625, sensitivity: 1, invertY: true)?.dy == 10)
    }
}

@Suite struct MotionReportTests {
    @Test func requestsTrackEachSensor() {
        var r = MotionRequests()
        #expect(!r.isActive)
        r.apply(type: UInt8(LI_MOTION_TYPE_GYRO), rateHz: 100)
        #expect(r.isActive)
        #expect(r.rateHz == 100)
        r.apply(type: UInt8(LI_MOTION_TYPE_ACCEL), rateHz: 1_000)
        #expect(r.rateHz == 200)   // capped
        r.apply(type: UInt8(LI_MOTION_TYPE_GYRO), rateHz: 0)
        r.apply(type: UInt8(LI_MOTION_TYPE_ACCEL), rateHz: 0)
        #expect(!r.isActive)
        #expect(r.rateHz == 0)
    }

    @Test func slowRequestsStillReportOftenEnough() {
        var r = MotionRequests()
        r.apply(type: UInt8(LI_MOTION_TYPE_GYRO), rateHz: 5)
        #expect(r.rateHz == 30)
    }

    @Test func unknownSensorsAreIgnored() {
        var r = MotionRequests()
        r.apply(type: 99, rateHz: 100)
        #expect(!r.isActive)
    }

    @Test func unitsAreWhatThePCExpects() {
        let g = MotionConversion.gyro([1, 0, -1])
        #expect(approximately(g.x, Float(degrees)))
        #expect(approximately(g.z, Float(-degrees)))
        let a = MotionConversion.acceleration([0, -1, 0])   // resting: gravity pulls down
        #expect(approximately(a.y, 9.80665))
    }

    @Test @MainActor func aPadWithoutSensorsReportsNothing() {
        let reporter = ControllerMotionReporter()
        reporter.attach(GCController.withExtendedGamepad())
        #expect(!reporter.canReport)
        reporter.hostRequested(type: UInt8(LI_MOTION_TYPE_GYRO), rateHz: 100)
        reporter.reset()
    }

    @Test @MainActor func tiltStaysOffUntilTurnedOnAndLive() {
        let hub = MotionHub()
        var sticks: [SIMD2<Float>] = []
        hub.onStick = { sticks.append($0) }
        hub.apply(FeelSnapshot(gyroMode: .rightStick))
        #expect(!hub.isRunning)        // not live yet
        #expect(sticks == [.zero])     // a mode change centres the stick
        hub.setLive(false)
        hub.apply(FeelSnapshot(gyroMode: .off))
        #expect(!hub.isRunning)
    }
}

@Suite struct GyroMergeTests {
    @Test func tiltAddsToAPhysicalPadsStick() {
        let merger = PhysicalPadMerger()
        var pad = GamepadState()
        pad.rightStick = [0.25, 0]
        _ = merger.physicalChanged(pad)
        #expect(merger.setGyro([0.5, 0.5]).rightStick == [0.75, 0.5])
        #expect(merger.hold(.guide).rightStick == [0.75, 0.5])   // a held button keeps the tilt
        #expect(merger.setGyro(.zero).rightStick == [0.25, 0])
    }

    @Test func resetForgetsTheTilt() {
        let merger = PhysicalPadMerger()
        _ = merger.setGyro([0.5, 0.5])
        merger.reset()
        #expect(merger.physicalChanged(GamepadState()).rightStick == .zero)
    }
}

@Suite @MainActor struct GyroResumeTests {
    @Test func tiltResumesAfterReleaseAll() {
        let sender = RecordingSender()
        let input = GamepadInput(sender: sender, schedulesWakeups: false)
        input.setGyroStick([0.5, 0])
        #expect(sender.sent.last?.rightStick == [0.5, 0])
        input.releaseAll()
        #expect(sender.sent.last?.rightStick == .zero)
        // The tilt source keeps sending the same value; it must reach the PC again.
        input.setGyroStick([0.5, 0])
        #expect(sender.sent.last?.rightStick == [0.5, 0])
    }

    @Test func everyModeChangeCentresTheStick() {
        let hub = MotionHub()
        var sticks: [SIMD2<Float>] = []
        hub.onStick = { sticks.append($0) }
        hub.apply(FeelSnapshot(gyroMode: .rightStick))
        hub.apply(FeelSnapshot(gyroMode: .off))
        hub.apply(FeelSnapshot(gyroMode: .rightStick))
        #expect(sticks == [.zero, .zero, .zero])   // every mode change re-centres
    }
}
