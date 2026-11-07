import Foundation

/// Whether a PC runs Pocket Rig Helper, as of the last check.
enum HelperStatus: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    /// Checked; nothing answered (no Helper, or the PC is off).
    case absent
    case present(HelperInfo)
    /// A Helper answered, but it speaks a newer version than this app understands.
    case needsAppUpdate

    var info: HelperInfo? {
        if case .present(let info) = self { return info }
        return nil
    }

    func can(_ capability: HelperCapability) -> Bool { info?.can(capability) ?? false }

    var steamReady: Bool { info?.steam.state == .ready }

    static let updateAppNote = "Update Pocket Rig to use this PC's Helper."
    static let pairAgainNote = "Pair this PC again to use its Helper."

    /// A line for screens that show Helper trouble, or nil when there's nothing to say beyond "no Helper".
    /// `needsRepair`: the Helper's certificate didn't match the one this phone paired with.
    static func problemNote(for status: HelperStatus, needsRepair: Bool) -> String? {
        if needsRepair { return pairAgainNote }
        if status == .needsAppUpdate { return updateAppNote }
        return nil
    }
}

/// Where the Helper answered.
struct HelperMatch: Sendable {
    let address: String
    let client: HelperClient
    let info: HelperInfo
}

/// Tries a PC's addresses one at a time until its Helper answers.
struct HelperLocator: Sendable {
    private let makeClient: @Sendable (String) -> HelperClient?

    init(makeClient: @escaping @Sendable (String) -> HelperClient?) { self.makeClient = makeClient }

    /// The address Sunshine just answered on first (it's known to work), then home-network, then Tailscale.
    static func order(preferred: String?, candidates: [String]) -> [String] {
        var seen = Set<String>()
        let lan = candidates.filter { !HostAddressResolver.isTailscale($0) }
        let tailscale = candidates.filter(HostAddressResolver.isTailscale)
        return ([preferred].compactMap { $0 } + lan + tailscale)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// How a search ended. `stopped` means it was cut short, which says nothing about the PC.
    enum Outcome: Sendable {
        case found(HelperMatch)
        case none
        /// Something answered with a certificate other than the one this phone paired with.
        case notPaired
        /// A Helper answered, but it speaks a newer API than this app does.
        case needsAppUpdate
        case stopped
    }

    func locate(addresses: [String]) async -> HelperMatch? {
        if case .found(let match) = await search(addresses: addresses) { return match }
        return nil
    }

    func search(addresses: [String]) async -> Outcome {
        var sawNotPaired = false
        var sawNewer = false
        for address in addresses {
            if Task.isCancelled { return .stopped }
            guard let client = makeClient(address) else { continue }
            // A second on top of the Sunshine probe time, for the TLS handshake.
            let timeout = HostAddressResolver.probeTimeout(for: address) + 1
            do {
                let info = try await client.info(timeout: timeout)
                // Only version 1 is understood. A newer Helper may change what the replies mean.
                if info.apiVersion > 1 { sawNewer = true; continue }
                guard info.apiVersion == 1 else { continue }
                return .found(HelperMatch(address: address, client: client, info: info))
            } catch is CancellationError {
                return .stopped
            } catch HelperError.notPaired {
                sawNotPaired = true
            } catch {
                continue
            }
        }
        if Task.isCancelled { return .stopped }
        if sawNewer { return .needsAppUpdate }
        return sawNotPaired ? .notPaired : .none
    }
}
