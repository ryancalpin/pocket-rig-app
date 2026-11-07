import Foundation
import Testing
@testable import PocketRig

/// A quality change (heat, network) reconnects through the same stop-and-resume path as a resize.
@Suite @MainActor struct StreamQualityRefitTests {
    private let small = PixelSize(width: 1000, height: 700)
    private let big = PixelSize(width: 1552, height: 1080)

    @MainActor final class Box { var kbps = 20_000 }

    /// Whether a reconnect may run (the player is watching the full screen).
    @MainActor final class Gate { var open = true }

    private func make(_ session: FakeResizableSession, box: Box, gate: Gate = Gate(),
                      did: @escaping () -> Void = {}) -> StreamResizeController {
        StreamResizeController(session: session, startSize: small,
                               debouncer: ResizeDebouncer(quietPeriod: .milliseconds(5)),
                               retryDelays: [.milliseconds(5)],
                               settingsFor: { size in
                                   var s = StreamSettings.default
                                   s.width = size.width
                                   s.height = size.height
                                   s.bitrateKbps = box.kbps
                                   return s
                               }, didReconnect: did, canReconnect: { gate.open })
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aQualityChangeAtTheSameSizeReconnectsOnce() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        let box = Box()
        var dids = 0
        let controller = make(session, box: box, did: { dids += 1 })
        box.kbps = 8_000
        controller.qualityChanged(size: small)
        await waitUntil { dids == 1 }
        #expect(session.reconnects.count == 1)
        #expect(session.reconnects.first?.width == 1000)
        #expect(session.reconnects.first?.bitrateKbps == 8_000)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.count == 1)   // and only once
    }

    @Test func aQualityChangeWithANewSizeUsesTheNewSize() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        var dids = 0
        let controller = make(session, box: Box(), did: { dids += 1 })
        controller.qualityChanged(size: big)
        await waitUntil { dids == 1 }
        #expect(session.reconnects.map(\.width) == [1552])
    }

    @Test func aQualityChangeWhileStoppedWaitsForTheStream() async {
        let session = FakeResizableSession()
        session.state = .failed(.disconnected)
        session.reconnectOutcome = .streaming
        var dids = 0
        let controller = make(session, box: Box(), did: { dids += 1 })
        controller.qualityChanged(size: small)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.isEmpty)
        session.state = .streaming
        controller.sessionStateChanged(.streaming)
        await waitUntil { dids == 1 }
        #expect(session.reconnects.count == 1)
    }

    @Test func nothingWantedNothingHappens() async {
        let session = FakeResizableSession()
        let controller = make(session, box: Box())
        controller.sessionStateChanged(.streaming)
        controller.propose(small)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.isEmpty)
    }
    // MARK: Fixes after the final review: nobody watching, nothing reconnects

    @Test func aQualityChangeWhileNobodyWatchesRunsOnceTheyAreBack() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        let box = Box(), gate = Gate()
        gate.open = false   // in the background, or in the floating window
        var dids = 0
        let controller = make(session, box: box, gate: gate, did: { dids += 1 })
        box.kbps = 8_000
        controller.qualityChanged(size: small)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.isEmpty)
        controller.resume()   // still nobody watching: still waits
        try? await Task.sleep(for: .milliseconds(30))
        #expect(session.reconnects.isEmpty)
        gate.open = true
        controller.resume()
        await waitUntil { dids == 1 }
        #expect(session.reconnects.map(\.bitrateKbps) == [8_000])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.count == 1)   // once
    }

    @Test func aWaitingQualityRefitStopsIfThePlayerLeavesDuringTheQuietPeriod() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        let gate = Gate()
        let controller = StreamResizeController(session: session, startSize: small,
                                                debouncer: ResizeDebouncer(quietPeriod: .milliseconds(40)),
                                                settingsFor: { _ in .default }, canReconnect: { gate.open })
        controller.qualityChanged(size: small)
        gate.open = false   // swiped home before the quiet period ended
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.reconnects.isEmpty)
        gate.open = true
        controller.resume()
        await waitUntil { session.reconnects.count == 1 }
        #expect(session.reconnects.count == 1)
    }

    @Test func aQualityChangeDuringARefitRunsAfterIt() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        session.reconnectDelay = .milliseconds(60)
        let box = Box()
        var dids = 0
        let controller = make(session, box: box, did: { dids += 1 })
        controller.propose(big)
        await waitUntil { session.reconnects.count == 1 }
        #expect(controller.isRefitting)
        box.kbps = 6_000
        controller.qualityChanged(size: big)   // arrives mid-refit, at the size being fitted
        await waitUntil { dids == 2 }
        #expect(session.reconnects.map(\.width) == [1552, 1552])
        #expect(session.reconnects.map(\.bitrateKbps) == [20_000, 6_000])
    }

    @Test func aFailedRefitHoldsItsRetryWhileNobodyWatches() async {
        let session = FakeResizableSession()
        session.startOutcomes = [.streaming]
        let gate = Gate()
        let controller = StreamResizeController(session: session, startSize: small,
                                                debouncer: ResizeDebouncer(quietPeriod: .milliseconds(5)),
                                                retryDelays: [.milliseconds(80)],
                                                settingsFor: { _ in .default }, canReconnect: { gate.open })
        controller.qualityChanged(size: small)
        await waitUntil { session.reconnects.count == 1 }
        gate.open = false   // the app left while the reconnect was failing
        await waitUntil { controller.isHoldingRetry }
        #expect(controller.isHoldingRetry)
        #expect(controller.hasUnfinishedRefit)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(session.starts == 0)   // no stream started with nobody watching
        gate.open = true
        controller.resume()
        await waitUntil { session.state == .streaming && !controller.isRefitting }
        #expect(session.starts == 1)
        #expect(!controller.hasUnfinishedRefit)
    }

    @Test func aRestartAfterAPauseUsesTheLatestQualityAndDoesNotRefitAgain() async {
        let session = FakeResizableSession()
        session.state = .ended   // paused for the background
        let box = Box()
        let controller = make(session, box: box)
        box.kbps = 5_000
        controller.qualityChanged(size: big)   // the phone warmed up while paused
        controller.streamWillRestart(at: big)
        #expect(session.storedSettings.map(\.bitrateKbps) == [5_000])
        #expect(session.storedSettings.map(\.width) == [1552])
        session.state = .streaming
        controller.sessionStateChanged(.streaming)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.reconnects.isEmpty)
    }

    @Test func theTextSaysWhyTheStreamReconnects() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        var dids = 0
        let controller = make(session, box: Box(), did: { dids += 1 })
        controller.qualityChanged(size: small)
        await waitUntil { dids == 1 }
        #expect(controller.reason == .quality)
        controller.propose(big)
        await waitUntil { dids == 2 }
        #expect(controller.reason == .resize)
        #expect(StreamStatusText.refitMessage(for: .quality) == "Adjusting quality…")
        #expect(StreamStatusText.refitMessage(for: .resize) == "Fitting the picture to the screen…")
    }
}

@Suite @MainActor struct QualityWatcherTests {
    @Test func networkDemoNames() {
        #expect(NetworkWatcher.demo(from: "cellular") == NetworkSnapshot(isExpensive: true))
        #expect(NetworkWatcher.demo(from: "lowData") == NetworkSnapshot(isConstrained: true))
        #expect(NetworkWatcher.demo(from: nil) == nil)
        #expect(NetworkWatcher.demo(from: "wifi") == nil)
    }

    @Test func thermalDemoNames() {
        #expect(ThermalWatcher.demo(from: "serious") == .serious)
        #expect(ThermalWatcher.demo(from: "critical") == .critical)
        #expect(ThermalWatcher.demo(from: "fair") == .fair)
        #expect(ThermalWatcher.demo(from: "hot") == nil)
    }

    @Test func aDemoValueStaysPut() {
        let network = NetworkWatcher(demo: NetworkSnapshot(isExpensive: true))
        network.start()
        #expect(network.snapshot.isExpensive)
        network.stop()
        let thermal = ThermalWatcher(demo: .critical)
        thermal.start()
        thermal.refresh()
        #expect(thermal.state == .critical)
        thermal.stop()
    }

    @Test func withoutADemoTheyStartFromTheRealPhone() {
        let thermal = ThermalWatcher(demo: nil)
        #expect(thermal.state == ProcessInfo.processInfo.thermalState)
        #expect(NetworkWatcher(demo: nil).snapshot == .home)   // until the first network report arrives
    }
}
