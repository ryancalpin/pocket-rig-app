import CoreGraphics
import Testing
@testable import PocketRig

@Suite @MainActor struct PoseMonitorTests {
    let fold = CGRect(x: 0, y: 465, width: 669, height: 21)

    @Test func firstWindowSizeAppliesAtOnce() {
        let monitor = PoseMonitor(settleDelay: .seconds(10))
        monitor.windowChanged(CGSize(width: 951, height: 669))
        #expect(monitor.pose == .sideways)
    }

    @Test func rotationAppliesAtOnce() {
        let monitor = PoseMonitor(settleDelay: .seconds(10))
        monitor.windowChanged(CGSize(width: 669, height: 951))
        monitor.windowChanged(CGSize(width: 951, height: 669))
        #expect(monitor.pose == .sideways)
    }

    @Test func closingAppliesAtOnce() {
        let monitor = PoseMonitor(settleDelay: .seconds(10))
        monitor.windowChanged(CGSize(width: 669, height: 951))
        monitor.hingeChanged(HingeReading(angleDegrees: 0, status: .closed))
        monitor.windowChanged(CGSize(width: 466, height: 678))
        #expect(monitor.pose == .cover)
    }

    @Test func foldWaitsToSettle() async throws {
        let monitor = PoseMonitor(settleDelay: .milliseconds(50))
        monitor.windowChanged(CGSize(width: 669, height: 951))
        monitor.foldChanged(fold)
        #expect(monitor.pose == .upright)
        #expect(monitor.candidate == .laptop)
        try await Task.sleep(for: .milliseconds(400))
        #expect(monitor.pose == .laptop)
    }

    @Test func hingeWobbleDoesNotFlipTheLayout() async throws {
        let monitor = PoseMonitor(settleDelay: .milliseconds(100))
        monitor.windowChanged(CGSize(width: 669, height: 951))
        monitor.foldChanged(fold)
        monitor.foldChanged(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(monitor.pose == .upright)
    }

    @Test func aHingeReadingMarksTheDeviceForGood() {
        let monitor = PoseMonitor()
        #expect(!monitor.hasHinge)
        monitor.hingeChanged(HingeReading(angleDegrees: 120, status: .partiallyOpen))
        #expect(monitor.hasHinge)
        monitor.hingeChanged(nil)
        #expect(monitor.hasHinge)
    }

    @Test func hingeAPIsAreCompiledIn() {
        #expect(DuoHinge.isCompiledIn)
    }
}
