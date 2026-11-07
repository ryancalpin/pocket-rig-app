import Testing
import Network
@testable import PocketRig

@Suite struct HostDiscoveryTests {
    @Test func ipv4ReturnsAddress() {
        let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 47989)
        #expect(HostDiscovery.address(from: ep) == "192.168.1.20")
    }
    @Test func ipv4ZoneIsStripped() {
        let ep = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20%lo0")!), port: 47989)
        #expect(HostDiscovery.address(from: ep) == "192.168.1.20")
    }
    @Test func ipv6ReturnsNil() {
        let ep = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 47989)
        #expect(HostDiscovery.address(from: ep) == nil)
    }
    @Test func nameReturnsNil() {
        let ep = NWEndpoint.hostPort(host: .name("rig.local", nil), port: 47989)
        #expect(HostDiscovery.address(from: ep) == nil)
    }
    @Test func nilEndpointReturnsNil() {
        #expect(HostDiscovery.address(from: nil) == nil)
    }
}
