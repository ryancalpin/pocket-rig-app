import Foundation
import SwiftData
import os

private let helperLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "helper")

extension AppModel {
    func helperStatus(for host: Host) -> HelperStatus { helperStatuses[host.serverUniqueID] ?? .unknown }

    func helperClient(for host: Host) -> HelperClient? { helperClients[host.serverUniqueID] }

    /// Looks for Pocket Rig Helper on this PC, trying `preferredAddress` (where Sunshine just answered)
    /// first. Saves the PC's wired network card for Wake-on-LAN when the Helper reports one.
    @discardableResult
    func refreshHelper(_ host: Host, preferredAddress: String?) async -> HelperStatus {
        let id = host.serverUniqueID
        // Each refresh takes a number; only the newest one may store its answer.
        let generation = (helperGenerations[id] ?? 0) + 1
        helperGenerations[id] = generation
        let hadContext = host.modelContext != nil
        guard let certPEM = host.serverCertPEM else {
            helperPresenceMisses[id] = nil
            if helperNeedsRepair.contains(id) { helperNeedsRepair.remove(id) }
            return setHelper(.absent, client: nil, for: id)
        }
        let make = makeHelperClient
        let locator = HelperLocator { address in make(address, certPEM) }
        let addresses = HelperLocator.order(preferred: preferredAddress, candidates: host.candidateAddresses)
        let outcome = await locator.search(addresses: addresses)
        // A newer check started while this one waited, or the PC was deleted: drop this answer.
        if helperGenerations[id] != generation { return helperStatus(for: host) }
        if hadContext && (host.modelContext == nil || host.isDeleted) { return .unknown }
        // A check cut short (the screen closed) says nothing new; keep the last answer.
        if case .stopped = outcome { return helperStatus(for: host) }
        // A certificate mismatch isn't "no Helper": keep what the screen showed and ask for pairing again.
        if case .notPaired = outcome {
            if !helperNeedsRepair.contains(id) { helperNeedsRepair.insert(id) }
            return helperStatus(for: host)
        }
        if helperNeedsRepair.contains(id) { helperNeedsRepair.remove(id) }
        if case .needsAppUpdate = outcome {
            helperPresenceMisses[id] = nil
            return setHelper(.needsAppUpdate, client: nil, for: id)
        }
        // A Helper that turns our certificate away looks the same as no Helper, so "absent" only means
        // "didn't answer this time"; the next refresh looks again.
        guard case .found(let match) = outcome else {
            // One missed search must not flicker the screen: a PC that had the Helper keeps it until the
            // second miss in a row. A PC that never had it is "absent" straight away.
            let misses = (helperPresenceMisses[id] ?? 0) + 1
            helperPresenceMisses[id] = misses
            if misses < 2, helperStatuses[id]?.info != nil { return helperStatus(for: host) }
            return setHelper(.absent, client: nil, for: id)
        }
        helperPresenceMisses[id] = nil
        #if DEBUG
        if !HelperDemo.isOn { rememberWake(match.info.wake, for: host) }
        #else
        rememberWake(match.info.wake, for: host)
        #endif
        return setHelper(.present(match.info), client: match.client, for: id)
    }

    /// Probes one PC without touching its "last connected" time, and without ever forgetting its pairing
    /// (a rejected probe shows "Needs pairing"; the stream screen's own connect decides). With
    /// `checkHelper`, also looks for Pocket Rig Helper at the address that answered. Returns the new status,
    /// or nil when the check was cancelled (no update).
    @discardableResult
    func probeHost(_ host: Host, checkHelper: Bool) async -> CoverHostStatus? {
        let id = host.serverUniqueID
        do {
            let connection = try await connect(host, touch: false, forgetOnFailure: false)
            let apps = try await connection.api.appList()
            let status = CoverHostStatus.make(info: connection.info, apps: apps)
            coverAPIs[id] = connection.api
            coverStatuses[id] = status
            recordStatus(host, status: status)
            if status.isOnline { wakes.clearNotice(id) }
            if checkHelper || helperStatus(for: host) == .unknown {
                await refreshHelper(host, preferredAddress: connection.address)
            }
            return status
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            let status = CoverHostStatus.failed(error)
            coverStatuses[id] = status
            recordStatus(host, status: status)
            return status
        }
    }

    /// Sends Wake-on-LAN to this PC's saved wired card. False when there's nothing to send to.
    func wake(_ host: Host) async -> Bool {
        guard let mac = host.macAddress, WakeOnLAN.isValidMAC(mac) else { return false }
        let sent = await WakeOnLAN.send(mac: mac, lanAddress: host.lanAddress, broadcast: host.wakeBroadcast)
        helperLog.info("Wake-on-LAN sent=\(sent, privacy: .public)")
        return sent
    }

    /// Updates this PC's downloads list when its Helper can give one. A missed check keeps the last list
    /// on screen, marks the PC in `helperDownloadFailures`, and adds one to `helperDownloadMisses`. A check
    /// cut short by cancellation counts as nothing. An answer that arrives after the Helper was
    /// re-checked, after the screen closed, or after the PC was deleted is dropped.
    func refreshDownloads(_ host: Host) async {
        let id = host.serverUniqueID
        guard helperStatus(for: host).can(.downloads), let client = helperClient(for: host) else { return }
        let generation = helperGenerations[id] ?? 0
        let hadContext = host.modelContext != nil
        func isStale() -> Bool {
            Task.isCancelled || helperGenerations[id] != generation
                || (hadContext && (host.modelContext == nil || host.isDeleted))
        }
        do {
            let downloads = try await client.downloads()
            if isStale() { return }
            if helperDownloads[id] != downloads { helperDownloads[id] = downloads }
            downloadActivities.update(serverUniqueID: id, pcName: host.name, downloads: downloads)
            if helperDownloadFailures.contains(id) { helperDownloadFailures.remove(id) }
            if helperDownloadMisses[id] != nil { helperDownloadMisses[id] = nil }
        } catch is CancellationError {
            return
        } catch {
            if isStale() { return }
            if !helperDownloadFailures.contains(id) { helperDownloadFailures.insert(id) }
            helperDownloadMisses[id, default: 0] += 1
        }
    }

    private func setHelper(_ status: HelperStatus, client: HelperClient?, for id: String) -> HelperStatus {
        if helperStatuses[id] != status { helperStatuses[id] = status }
        helperClients[id] = client
        if status.info == nil { helperDownloads[id] = nil; helperDownloadFailures.remove(id); helperDownloadMisses[id] = nil }
        return status
    }

    private func rememberWake(_ wake: HelperInfo.Wake?, for host: Host) {
        guard let wake, WakeOnLAN.isValidMAC(wake.mac) else { return }
        var changed = false
        if host.macAddress.flatMap(WakeOnLAN.macBytes) != WakeOnLAN.macBytes(wake.mac) {
            host.macAddress = wake.mac
            changed = true
        }
        if host.macAddressFromHelper != true {
            host.macAddressFromHelper = true
            changed = true
        }
        // A missing or unusable broadcast means the PC's network changed; forget the old one.
        let broadcast = wake.broadcast.flatMap { WakeOnLAN.isUsableBroadcast($0) ? $0 : nil }
        if host.wakeBroadcast != broadcast {
            host.wakeBroadcast = broadcast
            changed = true
        }
        guard changed else { return }
        do {
            try host.modelContext?.save()
        } catch {
            helperLog.error("Saving wake details failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
