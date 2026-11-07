import Foundation
import SwiftData

@Model
final class Host {
    @Attribute(.unique) var serverUniqueID: String
    var name: String
    var lanAddress: String?
    var tailscaleAddress: String?
    var serverCertPEM: Data?
    var macAddress: String?
    /// `macAddress` came from Pocket Rig Helper (the wired card). Sunshine's own answer is often the Wi-Fi
    /// card, so once the Helper has spoken it must not be overwritten. Optional so old saved data loads.
    var macAddressFromHelper: Bool?
    /// The PC's home-network broadcast address, from Pocket Rig Helper. Used only for Wake-on-LAN.
    var wakeBroadcast: String?
    var lastConnectedAt: Date?

    var isPaired: Bool { serverCertPEM != nil }

    /// LAN first, then Tailscale; empty entries and duplicates dropped.
    var candidateAddresses: [String] {
        var seen = Set<String>()
        return [lanAddress, tailscaleAddress]
            .compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    init(serverUniqueID: String, name: String, lanAddress: String?, tailscaleAddress: String?) {
        self.serverUniqueID = serverUniqueID
        self.name = name
        self.lanAddress = lanAddress
        self.tailscaleAddress = tailscaleAddress
    }
}
