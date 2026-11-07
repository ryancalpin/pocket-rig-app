import Foundation
import Testing
@testable import PocketRig

@Suite @MainActor struct StreamSessionReconnectTests {
    @Test func reconnectResumesWithTheNewSize() async throws {
        let gate = GatedRequester()   // no real reply: the PC "doesn't answer", so no real stream starts
        let session = makeSession(gate)
        let first = Task { await session.start() }
        await gate.waitForCalls(1)
        let next = settings(width: 1552)
        // Still launching: the reconnect only stores the size (a second request could kill the launch).
        await session.reconnect(with: next)
        #expect(gate.callCount == 1)
        gate.releaseAll()
        await first.value
        #expect(session.state == .failed(.unreachable))
        // The resize controller's retry resumes the failed session at the new size.
        await session.start()
        #expect(session.settings == next)
        #expect(session.state == .failed(.unreachable))
        #expect(gate.paths == ["/resume", "/resume"])
        #expect(gate.modes.last == "1552x1080x60")
    }

    // MARK: Stop and overlap safety

    private func makeSession(_ requester: HostRequesting, currentGameID: Int = 5) -> StreamSession {
        let info = ServerInfo(hostname: "PC", appVersion: "7.1.431.-1", gfeVersion: "", uniqueID: "U",
                              httpsPort: 47984, macAddress: "", localIP: "", codecModeSupport: 1, isPaired: true,
                              currentGameID: currentGameID, isBusy: currentGameID != 0, maxLumaPixelsHEVC: 0)
        return StreamSession(api: HostAPI(requester: requester, uniqueID: "U"), serverInfo: info,
                             address: "127.0.0.1", appID: 5, settings: .default)
    }

    private func settings(width: Int) -> StreamSettings {
        var s = StreamSettings.default
        s.width = width
        s.height = 1080
        return s
    }

    @Test func reconnectDuringALaunchOnlyUpdatesTheSettings() async {
        let gate = GatedRequester()
        let session = makeSession(gate, currentGameID: 0)   // nothing running: start sends /launch
        let first = Task { await session.start() }
        await gate.waitForCalls(1)
        #expect(session.state == .launching)
        let next = settings(width: 1552)
        await session.reconnect(with: next)   // returns at once; no second /launch, no /cancel
        #expect(session.settings == next)
        #expect(gate.callCount == 1)
        gate.releaseAll()
        await first.value
        #expect(gate.paths == ["/launch"])
        #expect(session.state == .failed(.unreachable))
    }

    @Test func reconnectOnAnEndedSessionDoesNotStart() async {
        let stub = StubRequester()
        let session = makeSession(stub)
        await session.stop()
        #expect(session.state == .ended)
        await session.reconnect(with: settings(width: 1552))
        #expect(session.state == .ended)
        #expect(session.settings.width == 1552)
        #expect(stub.calls.isEmpty)
    }

    @Test func reconnectBeforeStartDoesNotStart() async {
        let stub = StubRequester()
        let session = makeSession(stub)
        await session.reconnect(with: settings(width: 1552))
        #expect(session.state == .idle)
        #expect(stub.calls.isEmpty)
    }

    @Test func stopDuringAReconnectLeavesTheSessionEnded() async {
        let gate = GatedRequester()
        let session = makeSession(gate)
        let first = Task { await session.start() }
        await gate.waitForCalls(1)
        gate.releaseAll()
        await first.value   // the first try fails; a retry is now in flight, as after a failed refit
        gate.hold()
        let retry = Task { await session.start() }
        await gate.waitForCalls(2)
        await session.reconnect(with: settings(width: 1552))   // a resize arrives mid-retry
        await session.stop()
        gate.releaseAll()
        await retry.value
        #expect(session.state == .ended)
        #expect(gate.callCount == 2)
    }

    @Test func overlappingReconnectsEndWithTheLatestSettings() async {
        let gate = GatedRequester()
        let session = makeSession(gate)
        let first = Task { await session.start() }
        await gate.waitForCalls(1)
        await session.reconnect(with: settings(width: 1000))
        await session.reconnect(with: settings(width: 1552))
        #expect(gate.callCount == 1)   // neither reconnect touched the in-flight launch
        gate.releaseAll()
        await first.value
        #expect(session.settings.width == 1552)
        #expect(session.state == .failed(.unreachable))
        await session.start()   // the retry uses only the newest size
        #expect(gate.callCount == 2)
        #expect(gate.modes.last == "1552x1080x60")
    }
}

/// A requester whose calls wait until released, then fail as "unreachable" (no real stream starts).
final class GatedRequester: HostRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    private var released = false
    private var log: [(path: String, mode: String?)] = []

    var paths: [String] { lock.withLock { log.map(\.path) } }
    var modes: [String?] { lock.withLock { log.map(\.mode) } }

    var callCount: Int { lock.withLock { count } }

    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            count += 1
            log.append((path, query.first { $0.name == "mode" }?.value))
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
        throw HostError.unreachable
    }

    func waitForCalls(_ n: Int) async {
        for _ in 0..<500 where callCount < n { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Calls made after this wait again until the next `releaseAll()`.
    func hold() { lock.withLock { released = false } }

    func releaseAll() {
        lock.lock()
        released = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}

@Suite @MainActor struct StreamSessionFeedbackTests {
    private func makeSession() -> StreamSession {
        let info = ServerInfo(hostname: "PC", appVersion: "7.1.431.-1", gfeVersion: "", uniqueID: "U",
                              httpsPort: 47984, macAddress: "", localIP: "", codecModeSupport: 1, isPaired: true,
                              currentGameID: 5, isBusy: true, maxLumaPixelsHEVC: 0)
        return StreamSession(api: HostAPI(requester: StubRequester(), uniqueID: "U"), serverInfo: info,
                             address: "127.0.0.1", appID: 5, settings: .default)
    }

    private let rumble = StreamEvent.feedback(.rumble(controller: 0, low: 100, high: 0))

    @Test func feedbackReachesTheScreenWhileStreaming() {
        let session = makeSession()
        var got = 0
        session.onHostFeedback = { _ in got += 1 }
        session.setStateForTesting(.streaming)
        session.handle(rumble, token: session.bridgeToken)
        #expect(got == 1)
    }

    @Test func feedbackFromAnOldStreamIsDroppedAfterBeginReconnect() {
        let session = makeSession()
        var got = 0
        session.onHostFeedback = { _ in got += 1 }
        session.setStateForTesting(.streaming)
        let oldToken = session.bridgeToken
        session.beginReconnect()
        session.handle(rumble, token: oldToken)
        #expect(got == 0)
        session.handle(rumble, token: session.bridgeToken)   // the new token is live again once started
        #expect(got == 1)
    }

    @Test func beginReconnectDoesNothingOnAnIdleSession() {
        let session = makeSession()
        let token = session.bridgeToken
        session.beginReconnect()
        #expect(session.bridgeToken == token)
    }

    @Test func feedbackIsDroppedOnceTheStreamEnded() {
        let session = makeSession()
        var got = 0
        session.onHostFeedback = { _ in got += 1 }
        session.setStateForTesting(.ended)
        session.handle(rumble, token: session.bridgeToken)
        #expect(got == 0)
    }

    @Test func feedbackIsDroppedAfterAStop() async {
        let session = makeSession()
        var got = 0
        session.onHostFeedback = { _ in got += 1 }
        session.setStateForTesting(.streaming)
        let oldToken = session.bridgeToken
        await session.stop()
        session.handle(rumble, token: oldToken)
        #expect(got == 0)
    }
}
