import Foundation
import Observation
import SwiftData
import os

private let dataLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "data")

enum Route: Hashable {
    case pair(serverUniqueID: String)
    case apps(serverUniqueID: String)
    case stream(serverUniqueID: String, appID: Int)
}

extension Route {
    var isStream: Bool {
        if case .stream = self { return true }
        return false
    }
}

enum AppModelError: Error, Equatable {
    /// A Sunshine answered at the host's address, but it is a different PC.
    case differentHost
}

/// A verified, paired link to one host.
struct HostConnection: Sendable {
    let api: HostAPI
    let info: ServerInfo
    let address: String
}

@MainActor @Observable
final class AppModel {
    var path: [Route] = []
    /// DEBUG launch option: open this app once its host's app list loads. Cleared when used.
    var pendingAutoLaunchTitle: String?
    /// The mobile-data warning shows once per app launch, on the first stream that uses mobile data.
    @ObservationIgnored var hasShownDataWarning = false
    /// "Resume last game" is waiting for this PC's app list to load.
    var pendingResume: PendingLaunch?
    /// Bumped when "Resume last game" asks for the game already on screen; the stream screen brings it back
    /// out of the floating window.
    var showStreamRequests = 0
    /// App Group storage shared with the widget (tests swap in their own).
    @ObservationIgnored var sharedStore = SharedStore.standard()
    /// The Steam download Live Activity. Nothing shows until the app sets the real ActivityKit one.
    @ObservationIgnored var downloadActivities = DownloadActivityController(hosting: NoDownloadActivities())
    /// Last-known closed-phone status per PC, so reopening the cover doesn't restart at "Checking…".
    var coverStatuses: [String: CoverHostStatus] = [:]
    @ObservationIgnored var coverAPIs: [String: HostAPI] = [:]
    /// Pocket Rig Helper per PC (keyed by server ID), as of the last check.
    var helperStatuses: [String: HelperStatus] = [:]
    /// Last downloads list per PC, so the closed-phone card doesn't flash empty between checks.
    var helperDownloads: [String: [HelperDownload]] = [:]
    /// PCs whose last downloads check failed although the Helper is there (any number of misses in a row).
    var helperDownloadFailures: Set<String> = []
    /// How many downloads checks in a row failed per PC. The card only complains after two.
    var helperDownloadMisses: [String: Int] = [:]
    /// PCs whose Helper answered with a certificate that isn't the one this phone paired with.
    var helperNeedsRepair: Set<String> = []
    /// How many Helper searches in a row found nothing per PC. A PC that had the Helper stays "present"
    /// until the second miss.
    @ObservationIgnored var helperPresenceMisses: [String: Int] = [:]
    @ObservationIgnored var helperClients: [String: HelperClient] = [:]
    /// Counts Helper checks per PC so an older, slower answer can't overwrite a newer one.
    @ObservationIgnored var helperGenerations: [String: Int] = [:]

    /// Wake PC, shared by the cover and the PC list.
    let wakes = WakeCoordinator()

    @ObservationIgnored let identity: ClientIdentity
    @ObservationIgnored private let resolver: HostAddressResolver
    @ObservationIgnored private let makeRequester: @Sendable (String, Data?) -> HostRequesting
    /// `makeHelperClient(address, serverCertPEM)` builds a Pocket Rig Helper client; nil when it can't.
    @ObservationIgnored let makeHelperClient: @Sendable (String, Data) -> HelperClient?

    /// `makeRequester(address, serverCertPEM)` builds a client; a nil cert means plain HTTP only.
    /// `makeHelperClient` defaults to "no Helper anywhere", which is what tests that don't care want.
    init(identity: ClientIdentity, resolver: HostAddressResolver = .live,
         makeRequester: @escaping @Sendable (String, Data?) -> HostRequesting,
         makeHelperClient: @escaping @Sendable (String, Data) -> HelperClient? = { _, _ in nil }) {
        self.identity = identity
        self.resolver = resolver
        self.makeRequester = makeRequester
        self.makeHelperClient = makeHelperClient
    }

    // MARK: Navigation

    /// Swaps the top route for `new`, but only while `expected` is still on top. A screen that is no
    /// longer showing (the user backed out while it was loading) must not pop whatever is there now.
    func replaceTop(_ expected: Route, with new: Route) {
        guard path.last == expected else { return }
        if case .apps(let id) = expected { cancelPendingResume(for: id) }
        path[path.count - 1] = new
    }

    /// Leaves the pairing screen for the app list. If the app list is already right below it, go back to
    /// it instead of stacking a second copy. Does nothing unless the pairing screen is on top.
    func finishPairing(serverUniqueID: String) {
        guard path.last == .pair(serverUniqueID: serverUniqueID) else { return }
        path.removeLast()
        let apps = Route.apps(serverUniqueID: serverUniqueID)
        if path.last != apps { path.append(apps) }
    }

    // MARK: Hosts

    /// Asks the PC at `address` who it is (plain HTTP), then saves it, matched by its Sunshine unique ID.
    func addHost(address rawAddress: String, context: ModelContext) async throws -> Host {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw HostError.unreachable }
        let info = try await plainAPI(address).serverInfo(secure: false)
        guard !info.uniqueID.isEmpty else { throw HostError.malformed }

        let uniqueID = info.uniqueID
        let existing = try context.fetch(FetchDescriptor<Host>(predicate: #Predicate { $0.serverUniqueID == uniqueID }))
        let host: Host
        if let found = existing.first {
            host = found
            host.name = info.hostname
        } else {
            host = Host(serverUniqueID: uniqueID, name: info.hostname, lanAddress: nil, tailscaleAddress: nil)
            context.insert(host)
        }
        let typedIsTailscale = HostAddressResolver.isTailscale(address)
        if typedIsTailscale { host.tailscaleAddress = address } else { host.lanAddress = address }
        // Sunshine reports the address we reached it on; over Tailscale that's the Tailscale IP, so only a
        // non-Tailscale LocalIP tells us the home-network address. A LAN address the user typed has just
        // been proven to work, so it wins.
        if typedIsTailscale, !info.localIP.isEmpty, !HostAddressResolver.isTailscale(info.localIP) {
            host.lanAddress = info.localIP
        }
        // The Helper's wired-card address, once saved, is the better one: Sunshine often reports Wi-Fi.
        if host.macAddressFromHelper != true, !info.macAddress.isEmpty, info.macAddress != "00:00:00:00:00:00" {
            host.macAddress = info.macAddress
        }
        try context.save()
        return host
    }

    /// Finds an address where *this* host answers, then talks HTTPS pinned to its saved certificate.
    /// Throws `HostError.notPaired` (and forgets the certificate) when the host no longer accepts us.
    /// `touch: false` leaves `lastConnectedAt` (and the PC list order) alone. `forgetOnFailure: false` is for
    /// background status probes: they report `notPaired` but keep the certificate, because the address
    /// may briefly reach a different Sunshine; only a connect the user started forgets the pairing.
    func connect(_ host: Host, touch: Bool = true, forgetOnFailure: Bool = true) async throws -> HostConnection {
        func notPaired() throws -> Never {
            if forgetOnFailure { try forgetPairing(host) }
            throw HostError.notPaired
        }
        guard let certPEM = host.serverCertPEM else { throw HostError.notPaired }
        let address = try await reachableAddress(for: host)
        let api = HostAPI(requester: makeRequester(address, certPEM), uniqueID: identity.uniqueID)
        let info: ServerInfo
        do {
            info = try await api.serverInfo(secure: true)
        } catch HostError.certificatePinMismatch {
            try notPaired()
        } catch HostError.status(401, _) {
            try notPaired()
        }
        guard info.uniqueID.isEmpty || info.uniqueID == host.serverUniqueID else { throw AppModelError.differentHost }
        guard info.isPaired else { try notPaired() }
        if touch {
            host.lastConnectedAt = .now
            do {
                try host.modelContext?.save()
            } catch {
                // Only the "last connected" stamp is at stake; the connection itself is fine.
                dataLog.error("Saving lastConnectedAt failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return HostConnection(api: api, info: info, address: address)
    }

    /// Runs the PIN handshake and saves the host's certificate on success.
    func pair(_ host: Host, pin: String) async throws {
        let address = try await reachableAddress(for: host)
        let makeRequester = self.makeRequester
        let service = PairingService(requester: makeRequester(address, nil), identity: identity)
        let certPEM = try await service.pair(pin: pin) { certPEM in makeRequester(address, certPEM) }
        host.serverCertPEM = certPEM
        try host.modelContext?.save()
    }

    // MARK: Messages

    static func pairingMessage(for error: Error) -> String {
        switch error {
        case PairingError.alreadyInProgress:
            return "Sunshine is still waiting for an earlier PIN. Wait a few minutes or restart Sunshine, then try again."
        case HostError.status(let code, let message)
            where code == 409 || message.localizedCaseInsensitiveContains("already"):
            return pairingMessage(for: PairingError.alreadyInProgress)
        case PairingError.wrongPIN:
            return "The PIN didn't match. Try again, and type the new PIN into Sunshine."
        case PairingError.certificateMismatch:
            return "Your PC's identity didn't check out, so pairing stopped. Try again."
        case PairingError.serverRejected:
            return "Sunshine turned down the pairing request. Try again."
        case HostError.unreachable:
            return "Make sure your PC is on, Sunshine is running, and the PIN is entered within 2 minutes."
        case is HostError, AppModelError.differentHost:
            return message(for: error)
        default:
            dataLog.error("Unmapped pairing error: \(String(describing: error), privacy: .public)")
            return genericPairingMessage
        }
    }

    static let genericMessage = "Something went wrong. Try again."
    static let genericPairingMessage = "Something went wrong while pairing. Try again."

    static func message(for error: Error) -> String {
        switch error {
        case HostError.unreachable:
            return "Can't reach your PC. Make sure it's on and Sunshine is running."
        case AppModelError.differentHost:
            return "A different PC answered at this address. Check that you're on the right network."
        case HostError.notPaired, HostError.certificatePinMismatch:
            return "This PC needs to be paired again."
        case HostError.malformed:
            return "Your PC sent a reply Pocket Rig didn't understand."
        case HostError.status(let code, let message):
            return message.isEmpty ? "Your PC returned error \(code)." : "Your PC said: \(message) (\(code))"
        default:
            // Keep the technical detail in the log, not on screen.
            dataLog.error("Unmapped error: \(String(describing: error), privacy: .public)")
            return genericMessage
        }
    }

    // MARK: Private

    private func plainAPI(_ address: String) -> HostAPI {
        HostAPI(requester: makeRequester(address, nil), uniqueID: identity.uniqueID)
    }

    /// First candidate address that answers *and* reports this host's unique ID. A different Sunshine at
    /// the same IP (another network) is skipped so the next address (e.g. Tailscale) gets a turn.
    private func reachableAddress(for host: Host) async throws -> String {
        var remaining = host.candidateAddresses
        var sawOtherHost = false
        while let address = await resolver.firstReachable(remaining) {
            try Task.checkCancellation()
            if let index = remaining.firstIndex(of: address) { remaining.removeFirst(index + 1) } else { remaining = [] }
            guard let info = try? await plainAPI(address).serverInfo(secure: false) else { continue }
            if info.uniqueID == host.serverUniqueID { return address }
            sawOtherHost = true
        }
        try Task.checkCancellation()
        throw sawOtherHost ? AppModelError.differentHost : HostError.unreachable
    }

    private func forgetPairing(_ host: Host) throws {
        host.serverCertPEM = nil
        try host.modelContext?.save()
    }
}
