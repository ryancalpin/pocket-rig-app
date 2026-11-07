import Testing
import SwiftData
@testable import PocketRig

@Suite struct HostModelTests {
    @Test func candidateAddressesOrderLANFirstAndDropDuplicates() {
        let host = Host(serverUniqueID: "A", name: "Omen", lanAddress: "192.168.1.20", tailscaleAddress: "100.101.102.103")
        #expect(host.candidateAddresses == ["192.168.1.20", "100.101.102.103"])
        host.lanAddress = "100.101.102.103"
        #expect(host.candidateAddresses == ["100.101.102.103"])
    }
    @Test func persistsInMemoryContainer() throws {
        let container = try ModelContainer(for: Host.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Host(serverUniqueID: "A", name: "Omen", lanAddress: nil, tailscaleAddress: "100.101.102.103"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Host>()).first?.isPaired == false)
    }
}
