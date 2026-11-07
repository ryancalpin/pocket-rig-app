import Foundation
import SwiftData
import Testing
@testable import PocketRig

/// Answers Helper requests from a table keyed "METHOD /path"; anything else is "no answer".
struct FakeHelperRequester: HelperRequesting {
    var replies: [String: (body: String, status: Int)]

    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        guard let reply = replies["\(method) \(path)"] else { throw HelperError.unreachable }
        return (Data(reply.body.utf8), reply.status)
    }
}

/// Which addresses the app tried, and with which certificate.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _addresses: [String] = []
    private var _certs: [Data] = []

    func record(_ address: String, cert: Data = Data()) {
        lock.withLock { _addresses.append(address); _certs.append(cert) }
    }

    var addresses: [String] { lock.withLock { _addresses } }
    var certs: [Data] { lock.withLock { _certs } }
}

/// A switch a test can flip while the app holds a closure that reads it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) { _value = value }

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite @MainActor struct HelperStatusTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A paired PC with both addresses and the Wi-Fi MAC Sunshine reported.
    private func pairedHost(in context: ModelContext) throws -> Host {
        let host = Host(serverUniqueID: "SRV1", name: "Omen", lanAddress: "192.168.1.50", tailscaleAddress: "100.101.102.103")
        host.serverCertPEM = Data("PEM".utf8)
        host.macAddress = "b0:19:21:9e:2d:19"
        context.insert(host)
        try context.save()
        return host
    }

    /// A model whose Helper answers `infoJSON` only at `helperAddress`.
    private func model(_ log: CallLog, helperAddress: String?, infoJSON: String = HelperFixtures.readyInfo) throws -> AppModel {
        try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                     makeRequester: { _, _ in StubRequester() },
                     makeHelperClient: { address, cert in
                         log.record(address, cert: cert)
                         let replies: [String: (body: String, status: Int)] =
                             address == helperAddress ? ["GET /v1/info": (infoJSON, 200)] : [:]
                         return HelperClient(requester: FakeHelperRequester(replies: replies))
                     })
    }

    @Test func theAddressSunshineAnsweredOnGoesFirst() {
        #expect(HelperLocator.order(preferred: "100.101.102.103", candidates: ["192.168.1.50", "100.101.102.103"])
                == ["100.101.102.103", "192.168.1.50"])
        #expect(HelperLocator.order(preferred: nil, candidates: ["100.101.102.103", "192.168.1.50"])
                == ["192.168.1.50", "100.101.102.103"])
        #expect(HelperLocator.order(preferred: "", candidates: ["192.168.1.50", "192.168.1.50"]) == ["192.168.1.50"])
    }

    @Test func refreshFindsTheHelperAndRemembersTheWiredCard() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let log = CallLog()
        let model = try model(log, helperAddress: "100.101.102.103")

        let status = await model.refreshHelper(host, preferredAddress: "100.101.102.103")

        #expect(status.steamReady)
        #expect(status.can(.install))
        #expect(model.helperStatus(for: host) == status)
        #expect(model.helperClient(for: host) != nil)
        #expect(log.addresses == ["100.101.102.103"])
        #expect(log.certs == [Data("PEM".utf8)])
        // The Helper's wired card replaces the Wi-Fi MAC Sunshine reported: only the wired card can wake the PC.
        #expect(host.macAddress == "04:0e:3c:2a:36:94")
        #expect(host.wakeBroadcast == "192.168.1.255")
    }

    @Test func noHelperMeansAbsentAfterTryingEveryAddress() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let log = CallLog()
        let model = try model(log, helperAddress: nil)

        let status = await model.refreshHelper(host, preferredAddress: nil)

        #expect(status == .absent)
        #expect(log.addresses == ["192.168.1.50", "100.101.102.103"])
        #expect(model.helperClient(for: host) == nil)
        #expect(host.macAddress == "b0:19:21:9e:2d:19")
        #expect(host.wakeBroadcast == nil)
    }

    @Test func anUnpairedPCIsNeverAsked() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        host.serverCertPEM = nil
        let log = CallLog()
        let model = try model(log, helperAddress: "192.168.1.50")

        #expect(await model.refreshHelper(host, preferredAddress: "192.168.1.50") == .absent)
        #expect(log.addresses.isEmpty)
    }

    @Test func aHelperThatWentAwayIsForgotten() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let running = Flag(true)
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in
                                     let replies: [String: (body: String, status: Int)] =
                                         running.value ? ["GET /v1/info": (HelperFixtures.readyInfo, 200)] : [:]
                                     return HelperClient(requester: FakeHelperRequester(replies: replies))
                                 })
        #expect(await model.refreshHelper(host, preferredAddress: nil).info != nil)
        #expect(model.helperClient(for: host) != nil)
        running.value = false
        // One miss is forgiven: still present, same client.
        #expect(await model.refreshHelper(host, preferredAddress: nil).info != nil)
        #expect(model.helperClient(for: host) != nil)
        // The second miss in a row forgets it.
        #expect(await model.refreshHelper(host, preferredAddress: nil) == .absent)
        #expect(model.helperStatus(for: host) == .absent)
        #expect(model.helperClient(for: host) == nil)
    }

    @Test func oneMissedCheckKeepsTheHelperAndAnAnswerResetsTheCount() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let running = Flag(true)
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in
                                     let replies: [String: (body: String, status: Int)] =
                                         running.value ? ["GET /v1/info": (HelperFixtures.readyInfo, 200)] : [:]
                                     return HelperClient(requester: FakeHelperRequester(replies: replies))
                                 })
        await model.refreshHelper(host, preferredAddress: nil)
        running.value = false
        await model.refreshHelper(host, preferredAddress: nil)
        #expect(model.helperStatus(for: host).info != nil)
        running.value = true
        await model.refreshHelper(host, preferredAddress: nil)
        running.value = false
        await model.refreshHelper(host, preferredAddress: nil)
        #expect(model.helperStatus(for: host).info != nil, "an answer in between starts the count over")
    }

    @Test func olderOrBrokenAnswersDontCount() async throws {
        let log = CallLog()
        let locator = HelperLocator { address in
            log.record(address)
            let body = address == "10.0.0.1" ? #"{"apiVersion":0,"steam":{"state":"ready"}}"# : "not json"
            return HelperClient(requester: FakeHelperRequester(replies: ["GET /v1/info": (body, 200)]))
        }
        #expect(await locator.locate(addresses: ["10.0.0.1", "10.0.0.2"]) == nil)
        #expect(log.addresses == ["10.0.0.1", "10.0.0.2"])
    }

    @Test func aBadMACFromTheHelperIsIgnored() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let info = HelperFixtures.freshInfo.replacingOccurrences(of: "04:0e:3c:2a:36:94", with: "00:00:00:00:00:00")
        let model = try model(CallLog(), helperAddress: "192.168.1.50", infoJSON: info)
        let status = await model.refreshHelper(host, preferredAddress: nil)
        #expect(status.info?.steam.state == .notSetUp)
        #expect(!status.steamReady)
        #expect(host.macAddress == "b0:19:21:9e:2d:19")
    }

    @Test func aBadBroadcastIsNotSaved() async throws {
        for bad in ["0.0.0.0", "100.77.56.255", "not-an-ip"] {
            let context = try makeContext()
            let host = try pairedHost(in: context)
            host.wakeBroadcast = "192.168.1.255"
            let info = HelperFixtures.readyInfo.replacingOccurrences(of: "192.168.1.255", with: bad)
            let model = try model(CallLog(), helperAddress: "192.168.1.50", infoJSON: info)
            _ = await model.refreshHelper(host, preferredAddress: nil)
            #expect(host.macAddress == "04:0e:3c:2a:36:94")
            #expect(host.wakeBroadcast == nil, "\(bad)")
        }
    }

    @Test func aMissingBroadcastClearsTheOldOne() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        host.wakeBroadcast = "10.0.0.255"
        let info = HelperFixtures.readyInfo.replacingOccurrences(of: #""broadcast":"192.168.1.255""#, with: #""x":1"#)
        #expect(!info.contains("192.168.1.255"))
        let model = try model(CallLog(), helperAddress: "192.168.1.50", infoJSON: info)
        _ = await model.refreshHelper(host, preferredAddress: nil)
        #expect(host.macAddress == "04:0e:3c:2a:36:94")
        #expect(host.wakeBroadcast == nil)
    }

    @Test func theSameMACInAnotherStyleIsNotAChange() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        host.macAddress = "04-0E-3C-2A-36-94"
        let model = try model(CallLog(), helperAddress: "192.168.1.50")
        _ = await model.refreshHelper(host, preferredAddress: nil)
        #expect(host.macAddress == "04-0E-3C-2A-36-94")
    }

    /// A requester that answers after a delay.
    private struct SlowRequester: HelperRequesting {
        var body: String
        var delay: Duration
        func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
            try await Task.sleep(for: delay)
            return (Data(body.utf8), 200)
        }
    }

    @Test func anOlderSlowAnswerCannotOverwriteANewerOne() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        host.macAddress = nil
        let slowBody = HelperFixtures.freshInfo.replacingOccurrences(of: "04:0e:3c:2a:36:94", with: "04:0e:3c:aa:aa:aa")
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { address, _ in
                                     address == "192.168.1.50"
                                         ? HelperClient(requester: SlowRequester(body: slowBody, delay: .milliseconds(400)))
                                         : HelperClient(requester: SlowRequester(body: HelperFixtures.readyInfo, delay: .milliseconds(10)))
                                 })
        let older = Task { await model.refreshHelper(host, preferredAddress: "192.168.1.50") }
        let newer = Task { await model.refreshHelper(host, preferredAddress: "100.101.102.103") }
        let newerStatus = await newer.value
        _ = await older.value
        #expect(newerStatus.steamReady)
        #expect(model.helperStatus(for: host) == newerStatus)
        #expect(host.macAddress == "04:0e:3c:2a:36:94")
    }

    @Test func aPCDeletedMidCheckStoresNothing() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let id = host.serverUniqueID
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in
                                     HelperClient(requester: SlowRequester(body: HelperFixtures.readyInfo, delay: .milliseconds(200)))
                                 })
        let check = Task { await model.refreshHelper(host, preferredAddress: nil) }
        try await Task.sleep(for: .milliseconds(50))
        context.delete(host)
        try context.save()
        _ = await check.value
        #expect(model.helperStatuses[id] == nil)
        #expect(model.helperClients[id] == nil)
    }

    @Test func statusAnswersSafelyWhenUnknown() throws {
        #expect(!HelperStatus.unknown.can(.sleep))
        #expect(!HelperStatus.absent.steamReady)
        #expect(HelperStatus.unknown.info == nil)
        let fresh = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.freshInfo))
        #expect(fresh.can(.sleep))
        #expect(!fresh.can(.library))
    }

    @Test func onlyAPIVersionOneIsAccepted() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let newer = HelperFixtures.readyInfo.replacingOccurrences(of: #""apiVersion":1"#, with: #""apiVersion":2"#)
        let status = await (try model(CallLog(), helperAddress: "192.168.1.50", infoJSON: newer))
            .refreshHelper(host, preferredAddress: nil)
        #expect(status == .needsAppUpdate)
        #expect(status.info == nil)
        #expect(!status.can(.install))
        #expect(HelperStatus.problemNote(for: status, needsRepair: false) == HelperStatus.updateAppNote)
        #expect(PCControl.unavailableNote(for: status) == HelperStatus.updateAppNote)
        let zero = HelperFixtures.readyInfo.replacingOccurrences(of: #""apiVersion":1"#, with: #""apiVersion":0"#)
        let none = await (try model(CallLog(), helperAddress: "192.168.1.50", infoJSON: zero))
            .refreshHelper(host, preferredAddress: nil)
        #expect(none == .absent)
    }

    @Test func aCertificateMismatchKeepsTheLastStatusAndAsksToPairAgain() async throws {
        let context = try makeContext()
        let host = try pairedHost(in: context)
        let mismatch = Flag(false)
        struct Mismatched: HelperRequesting {
            func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) { throw HelperError.notPaired }
        }
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in StubRequester() },
                                 makeHelperClient: { _, _ in
                                     mismatch.value
                                         ? HelperClient(requester: Mismatched())
                                         : HelperClient(requester: FakeHelperRequester(replies: ["GET /v1/info": (HelperFixtures.readyInfo, 200)]))
                                 })
        let good = await model.refreshHelper(host, preferredAddress: nil)
        #expect(good.info != nil)
        mismatch.value = true
        let after = await model.refreshHelper(host, preferredAddress: nil)
        #expect(after == good)                                  // not flipped to absent
        #expect(model.helperStatus(for: host) == good)
        #expect(model.helperNeedsRepair.contains(host.serverUniqueID))
        #expect(HelperStatus.problemNote(for: after, needsRepair: true) == HelperStatus.pairAgainNote)
        // Paired again: the flag goes away.
        mismatch.value = false
        _ = await model.refreshHelper(host, preferredAddress: nil)
        #expect(!model.helperNeedsRepair.contains(host.serverUniqueID))
    }

    @Test func searchReportsAMismatchAsItsOwnOutcome() async {
        struct Mismatched: HelperRequesting {
            func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) { throw HelperError.notPaired }
        }
        let locator = HelperLocator { _ in HelperClient(requester: Mismatched()) }
        guard case .notPaired = await locator.search(addresses: ["192.168.1.50"]) else {
            Issue.record("expected .notPaired")
            return
        }
    }

    @Test func theHelpersWiredAddressIsNotOverwrittenBySunshines() async throws {
        let context = try makeContext()
        let stub = StubRequester()
        let xml = #"<root status_code="200"><hostname>Omen</hostname><uniqueid>SRV1</uniqueid><LocalIP>192.168.1.20</LocalIP><mac>b0:19:21:9e:2d:19</mac><PairStatus>0</PairStatus></root>"#
        stub.responses["/serverinfo"] = xml
        let model = try AppModel(identity: HelperFixtures.identity(), resolver: HostAddressResolver { _ in true },
                                 makeRequester: { _, _ in stub },
                                 makeHelperClient: { _, _ in
                                     HelperClient(requester: FakeHelperRequester(replies: ["GET /v1/info": (HelperFixtures.readyInfo, 200)]))
                                 })
        let host = try await model.addHost(address: "192.168.1.20", context: context)
        #expect(host.macAddress == "b0:19:21:9e:2d:19")          // Sunshine's, until the Helper speaks
        host.serverCertPEM = Data("PEM".utf8)
        _ = await model.refreshHelper(host, preferredAddress: nil)
        #expect(host.macAddress == "04:0e:3c:2a:36:94")
        #expect(host.macAddressFromHelper == true)
        let again = try await model.addHost(address: "192.168.1.20", context: context)   // re-add
        #expect(again.macAddress == "04:0e:3c:2a:36:94")
    }
}
