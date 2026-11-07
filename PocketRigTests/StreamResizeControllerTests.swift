import Foundation
import Testing
@testable import PocketRig

/// A session whose reconnect and start outcomes the test scripts.
@MainActor final class FakeResizableSession: ResizableSession {
    var state: StreamState = .streaming
    var reconnects: [StreamSettings] = []
    var starts = 0
    /// Outcome of each `start()` call in order; the last repeats.
    var startOutcomes: [StreamState] = [.streaming]
    var reconnectOutcome: StreamState = .failed(.startFailed)

    var log: [String] = []

    func beginReconnect() { log.append("begin") }

    /// How long a reconnect takes (none by default).
    var reconnectDelay: Duration = .zero

    func reconnect(with settings: StreamSettings) async {
        reconnects.append(settings)
        if reconnectDelay > .zero { try? await Task.sleep(for: reconnectDelay) }
        state = reconnectOutcome
    }

    func start() async {
        let index = min(starts, startOutcomes.count - 1)
        starts += 1
        state = startOutcomes[index]
    }

    var storedSettings: [StreamSettings] = []

    func updateSettings(_ settings: StreamSettings) { storedSettings.append(settings) }
}

@Suite @MainActor struct StreamResizeControllerTests {
    private let small = PixelSize(width: 1000, height: 700)
    private let big = PixelSize(width: 1552, height: 1080)

    private func make(_ session: FakeResizableSession, retryDelays: [Duration] = [.milliseconds(5), .milliseconds(5)],
                      will: @escaping () -> Void = {}, did: @escaping () -> Void = {}) -> StreamResizeController {
        StreamResizeController(session: session, startSize: small,
                               debouncer: ResizeDebouncer(quietPeriod: .milliseconds(5)),
                               retryDelays: retryDelays,
                               settingsFor: { size in
                                   var s = StreamSettings.default
                                   s.width = size.width
                                   s.height = size.height
                                   return s
                               }, willReconnect: will, didReconnect: did)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aLastingSizeChangeReconnectsOnce() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        var wills = 0, dids = 0
        let controller = make(session, will: { wills += 1 }, did: { dids += 1 })
        controller.propose(big)
        await waitUntil { dids == 1 }
        #expect(session.reconnects.count == 1)
        #expect(session.reconnects.first?.width == 1552)
        #expect(session.starts == 0)
        #expect(wills == 1)
        #expect(!controller.isRefitting)
    }

    @Test func theOldStreamIsCutOffBeforeTheMotorsAreSilenced() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        var dids = 0
        let controller = make(session, will: { session.log.append("will") }, did: { dids += 1 })
        controller.propose(big)
        await waitUntil { dids == 1 }
        #expect(session.log == ["begin", "will"])
    }

    @Test func aFailedRefitIsRetriedUntilItComesUp() async {
        let session = FakeResizableSession()
        session.startOutcomes = [.failed(.startFailed), .streaming]
        let controller = make(session)
        controller.propose(big)
        await waitUntil { session.state == .streaming && session.starts == 2 && !controller.isRefitting }
        #expect(session.reconnects.count == 1)
        #expect(session.starts == 2)
        #expect(session.state == .streaming)
        #expect(!controller.isRefitting)
    }

    @Test func retriesStopAfterTheLastDelayAndTryAgainResumes() async {
        let session = FakeResizableSession()
        session.startOutcomes = [.failed(.startFailed)]
        let controller = make(session)
        controller.propose(big)
        await waitUntil { session.starts == 2 && !controller.isRefitting }
        #expect(session.starts == 2)          // exactly the two retries, no more
        #expect(session.state == .failed(.startFailed))
        #expect(!controller.isRefitting)      // the screen now offers "Try again"

        session.startOutcomes = [.streaming]
        session.starts = 0
        controller.tryAgain()
        await waitUntil { session.state == .streaming && !controller.isRefitting }
        #expect(session.starts == 1)
        #expect(session.state == .streaming)
    }

    @Test func tryAgainDoesNothingWhileStreaming() async {
        let session = FakeResizableSession()
        let controller = make(session)
        controller.tryAgain()
        #expect(session.starts == 0)
        #expect(!controller.isRefitting)
    }

    @Test func aSizeWantedDuringARefitIsAppliedAfterwards() async {
        let session = FakeResizableSession()
        session.reconnectOutcome = .streaming
        var dids = 0
        let controller = make(session, did: { dids += 1 })
        controller.propose(big)
        await waitUntil { controller.isRefitting }
        controller.propose(PixelSize(width: 800, height: 600))   // arrives mid-refit
        await waitUntil { session.reconnects.count == 2 && !controller.isRefitting }
        #expect(session.reconnects.map(\.width) == [1552, 800])
    }

    @Test func tryAgainResumesWithoutTheRefitSpinner() async {
        let session = FakeResizableSession()
        session.state = .failed(.launchRejected)
        let controller = make(session)
        controller.tryAgain()
        #expect(!controller.isRefitting)   // the normal "Starting…" text shows, not "Fitting the picture…"
        await waitUntil { session.state == .streaming }
        #expect(session.starts == 1)
        #expect(session.reconnects.isEmpty)
    }

    @Test func leavingStopsTheRetries() async {
        let session = FakeResizableSession()
        session.startOutcomes = [.failed(.startFailed)]
        var dids = 0
        let controller = make(session, retryDelays: [.milliseconds(50), .milliseconds(50)], did: { dids += 1 })
        controller.propose(big)
        await waitUntil { session.reconnects.count == 1 }
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(session.starts == 0)
        #expect(dids == 0)
        controller.tryAgain()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.starts == 0)
    }
}
