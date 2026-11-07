import Foundation
import Network
import dnssd
import Observation

struct DiscoveredHost: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let address: String
}

@MainActor @Observable
final class HostDiscovery {
    private(set) var hosts: [DiscoveredHost] = []
    /// True when iOS blocked Local Network access; the UI should show guidance.
    private(set) var permissionDenied = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connections: [String: NWConnection] = [:]
    @ObservationIgnored private var hasRetriedBrowser = false
    @ObservationIgnored private let queue = DispatchQueue(label: "pocketrig.discovery")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [(String, NWEndpoint)] = results.compactMap {
                if case let .service(name, _, _, _) = $0.endpoint { return (name, $0.endpoint) }
                return nil
            }
            Task { @MainActor in self?.handle(services) }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            switch state {
            case .failed:
                Task { @MainActor in self?.browserFailed(browser) }
            case .waiting(let error):
                let denied = Self.isPermissionDenied(error)
                Task { @MainActor in self?.permissionDenied = denied }
            case .ready:
                Task { @MainActor in self?.permissionDenied = false }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func browserFailed(_ failed: NWBrowser?) {
        guard let failed, failed === browser else { return }
        failed.cancel()
        browser = nil
        guard !hasRetriedBrowser else { return }
        hasRetriedBrowser = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    nonisolated static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    private func handle(_ services: [(String, NWEndpoint)]) {
        let names = Set(services.map(\.0))
        hosts.removeAll { !names.contains($0.id) }
        for (name, connection) in connections where !names.contains(name) {
            connection.cancel()
            connections[name] = nil
        }
        for (name, endpoint) in services
        where connections[name] == nil && !hosts.contains(where: { $0.id == name }) {
            resolve(name: name, endpoint: endpoint)
        }
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        connections[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                let address = Self.address(from: connection.currentPath?.remoteEndpoint)
                connection.cancel()
                Task { @MainActor in self?.resolved(name: name, address: address, connection: connection) }
            case .failed, .cancelled, .waiting:
                connection.cancel()
                Task { @MainActor in self?.abandon(name: name, connection: connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { [weak self, weak connection] in
            guard let connection else { return }
            connection.cancel()
            Task { @MainActor in self?.abandon(name: name, connection: connection) }
        }
    }

    /// Drops the pending entry only if it is still this connection, so a later retry isn't clobbered.
    private func abandon(name: String, connection: NWConnection) {
        if connections[name] === connection { connections[name] = nil }
    }

    private func resolved(name: String, address: String?, connection: NWConnection) {
        abandon(name: name, connection: connection)
        guard let address, !hosts.contains(where: { $0.id == name }) else { return }
        hosts.append(DiscoveredHost(id: name, name: name, address: address))
    }

    /// IPv4 host string from a resolved endpoint, with any `%iface` zone suffix removed.
    /// Returns nil for IPv6, names, and anything else.
    nonisolated static func address(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(.ipv4(a), _)? = endpoint else { return nil }
        return "\(a)".split(separator: "%", maxSplits: 1).first.map(String.init)
    }
}
