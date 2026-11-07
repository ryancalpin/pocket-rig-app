import Foundation
import Network

/// Wake-on-LAN: a "magic packet" (six 0xFF bytes, then the PC's network-card address 16 times) sent over
/// UDP. The PC's wired card must have a cable in and wake turned on in the BIOS and in Ubuntu.
enum WakeOnLAN {
    static let port: UInt16 = 9

    static let wakingMessage = "Waking your PC… It can take up to a minute."
    static let noAnswerMessage = "Your PC didn't wake up. Wake-on-LAN needs the PC on a network cable, with waking turned on."
    static let notSentMessage = "Couldn't send the wake signal. Make sure this phone is on your home Wi-Fi."

    /// Six hex pairs split by ":" or "-". All-zero and all-FF addresses aren't real cards.
    static func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { part in
            part.count == 2 && part.allSatisfy(\.isHexDigit) ? UInt8(part, radix: 16) : nil
        }
        // Not all-zero, not all-FF, and not a group address (low bit of the first byte): none are real cards.
        guard bytes.count == 6, bytes != Array(repeating: 0, count: 6), bytes != Array(repeating: 0xff, count: 6),
              bytes[0] & 1 == 0 else {
            return nil
        }
        return bytes
    }

    static func isValidMAC(_ mac: String) -> Bool { macBytes(mac) != nil }

    /// A network's broadcast address worth saving: a real IPv4 address, not Tailscale, not 0.0.0.0.
    static func isUsableBroadcast(_ address: String) -> Bool {
        IPv4Address(address) != nil && address != "0.0.0.0" && !HostAddressResolver.isTailscale(address)
    }

    static func magicPacket(mac: String) -> Data? {
        guard let bytes = macBytes(mac) else { return nil }
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// The PC's own home-network address, its network's broadcast, and the all-networks broadcast.
    /// Tailscale addresses are skipped: a sleeping PC isn't on Tailscale.
    static func targets(lanAddress: String?, broadcast: String?) -> [String] {
        var list: [String] = []
        for address in [lanAddress, broadcast, "255.255.255.255"] {
            guard let address, IPv4Address(address) != nil, !HostAddressResolver.isTailscale(address),
                  !list.contains(address) else { continue }
            list.append(address)
        }
        return list
    }

    /// Sends the packet to every target at once. True when at least one left the phone.
    static func send(mac: String, lanAddress: String?, broadcast: String?) async -> Bool {
        guard let packet = magicPacket(mac: mac) else { return false }
        let hosts = targets(lanAddress: lanAddress, broadcast: broadcast)
        return await withTaskGroup(of: Bool.self) { group in
            for host in hosts { group.addTask { await sendOne(packet, to: host) } }
            var anySent = false
            for await sent in group { anySent = anySent || sent }
            return anySent
        }
    }

    private static func sendOne(_ packet: Data, to host: String) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return false }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        let queue = DispatchQueue(label: "com.ryancalpin.pocketrig.wol")
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { sent in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: sent)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { error in finish(error == nil) })
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }

    /// Lets exactly one of several callbacks finish the send.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.withLock {
                guard !done else { return false }
                done = true
                return true
            }
        }
    }
}
