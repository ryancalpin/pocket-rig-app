import Foundation

struct HostAddressResolver: Sendable {
    typealias Probe = @Sendable (String) async -> Bool

    private let probe: Probe

    init(probe: @escaping Probe) { self.probe = probe }

    /// Probes addresses in order, one at a time; returns the first that answers.
    func firstReachable(_ addresses: [String]) async -> String? {
        for address in addresses {
            if Task.isCancelled { return nil }
            if await probe(address) { return address }
        }
        return nil
    }

    /// True for IPv4 addresses in 100.64.0.0/10 (Tailscale CGNAT range).
    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// Seconds to wait for a probe. Tailscale can start on a slow relay path, so it gets longer than the LAN.
    static func probeTimeout(for address: String) -> TimeInterval {
        isTailscale(address) ? 3.5 : 1.5
    }

    static let live = HostAddressResolver { address in
        let host = address.contains(":") ? "[\(address)]" : address
        guard let url = URL(string: "http://\(host):47989/serverinfo") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout(for: address)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
