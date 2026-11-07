import Testing
import Foundation
@testable import PocketRig

@Suite struct HostAddressResolverTests {
    @Test func prefersLANWhenReachable() async {
        let resolver = HostAddressResolver { $0 == "192.168.1.20" || $0 == "100.101.102.103" }
        #expect(await resolver.firstReachable(["192.168.1.20", "100.101.102.103"]) == "192.168.1.20")
    }
    @Test func fallsBackToTailscale() async {
        let resolver = HostAddressResolver { $0 == "100.101.102.103" }
        #expect(await resolver.firstReachable(["192.168.1.20", "100.101.102.103"]) == "100.101.102.103")
    }
    @Test func nilWhenNothingAnswers() async {
        #expect(await HostAddressResolver { _ in false }.firstReachable(["10.0.0.1"]) == nil)
    }
    @Test func detectsTailscaleRange() {
        #expect(HostAddressResolver.isTailscale("100.101.102.103"))
        #expect(!HostAddressResolver.isTailscale("100.128.0.1"))
        #expect(!HostAddressResolver.isTailscale("192.168.1.2"))
        #expect(!HostAddressResolver.isTailscale("fe80::1"))
    }
    @Test func tailscaleGetsALongerProbeTimeout() {
        #expect(HostAddressResolver.probeTimeout(for: "100.101.102.103") == 3.5)
        #expect(HostAddressResolver.probeTimeout(for: "192.168.1.20") == 1.5)
        #expect(HostAddressResolver.probeTimeout(for: "100.128.0.1") == 1.5)
    }
    @Test func lanSuccessDoesNotProbeTailscale() async {
        let probed = LockedBox<[String]>([])
        let resolver = HostAddressResolver { address in
            probed.mutate { $0.append(address) }
            return true
        }
        #expect(await resolver.firstReachable(["192.168.1.20", "100.101.102.103"]) == "192.168.1.20")
        #expect(probed.value == ["192.168.1.20"])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PR_LIVE"] == "1"))
    func liveProbeAgainstRealHost() async throws {
        #expect(await HostAddressResolver.live.firstReachable([LiveStreamSmokeTests.address]) == LiveStreamSmokeTests.address)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}
