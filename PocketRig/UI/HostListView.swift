import SwiftData
import SwiftUI
import os

private let dataLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "data")

struct HostListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Host.name) private var hosts: [Host]
    @State private var discovery = HostDiscovery()
    @State private var showingAddAlert = false
    @State private var addressText = ""
    @State private var busyAddress: String?
    @State private var errorMessage: String?
    @State private var deleteFailed = false
    @State private var showingFeel = false
    @State private var showingAbout = DebugLaunchOptions.flag("openAbout")
    @Environment(\.scenePhase) private var scenePhase

    /// One saved PC on the list: the real ones, or sample ones for `-pr.hostListDemo YES` (DEBUG).
    private struct SavedRow: Identifiable {
        let id: String
        let name: String
        let address: String
        let isPaired: Bool
        let isOffline: Bool
        /// Offered Wake PC: offline, with a valid saved network-card address.
        let offersWake: Bool
        /// Nil for sample rows.
        let host: Host?
    }

    private var savedRows: [SavedRow] {
        #if DEBUG
        if DebugLaunchOptions.flag("hostListDemo") {
            return [SavedRow(id: "Gaming PC", name: "Gaming PC", address: "192.168.1.50", isPaired: true,
                             isOffline: false, offersWake: false, host: nil),
                    SavedRow(id: "Office PC", name: "Office PC", address: "192.168.1.40", isPaired: true,
                             isOffline: true, offersWake: true, host: nil)]
        }
        #endif
        return hosts.map { host in
            let status = host.isPaired ? model.coverStatuses[host.serverUniqueID] : nil
            return SavedRow(id: host.serverUniqueID, name: host.name, address: host.candidateAddresses.first ?? "No address",
                            isPaired: host.isPaired, isOffline: status == .offline,
                            offersWake: WakeCoordinator.canOffer(status: status, macAddress: host.macAddress), host: host)
        }
    }

    /// Discovered PCs whose address isn't already one of a saved host's.
    private var newDiscoveries: [DiscoveredHost] {
        let known = Set(hosts.flatMap(\.candidateAddresses))
        return discovery.hosts.filter { !known.contains($0.address) }
    }

    var body: some View {
        Group {
            if savedRows.isEmpty && newDiscoveries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("PCs")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Vibration and aiming", systemImage: "gearshape") { showingFeel = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("About Pocket Rig", systemImage: "info.circle") { showingAbout = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add PC by address", systemImage: "plus") {
                    addressText = ""
                    showingAddAlert = true
                }
                .disabled(busyAddress != nil)
            }
        }
        .alert("Add PC by address", isPresented: $showingAddAlert) {
            TextField("IP address", text: $addressText)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { add(address: addressText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type your PC's IP address, like 192.168.1.20 or its Tailscale address.")
        }
        .alert("Couldn't add PC", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Couldn't remove this PC.", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showingFeel) {
            FeelSettingsSheet(settings: FeelSettings.current(in: context))
        }
        .sheet(isPresented: $showingAbout) { AboutScreen() }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop(); model.wakes.stopAll() }
        // Polling only runs while this list is in front and the app is active.
        .task(id: scenePhase) { if scenePhase == .active { await statusLoop() } }
    }

    // MARK: Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PCs yet", systemImage: "desktopcomputer")
        } description: {
            VStack(spacing: 8) {
                Text("Make sure your PC is on and Sunshine is running, or add it by address.")
                if discovery.permissionDenied { Text(Self.permissionText) }
            }
        } actions: {
            Button("Add PC by address") {
                addressText = ""
                showingAddAlert = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busyAddress != nil)
            if busyAddress != nil { ProgressView("Adding…") }
        }
    }

    private var list: some View {
        List {
            if discovery.permissionDenied {
                Section {
                    Label(Self.permissionText, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !savedRows.isEmpty {
                Section("Saved") {
                    ForEach(savedRows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { if let host = row.host { open(host) } } label: {
                                HostRow(name: row.name, address: row.address,
                                        status: row.isOffline ? "Offline" : (row.isPaired ? "Paired" : "Not paired"),
                                        isPaired: row.isPaired, isOffline: row.isOffline, isBusy: false)
                            }
                            .buttonStyle(.plain)
                            .disabled(busyAddress != nil)
                            if row.offersWake { WakePCButton(id: row.id, name: row.name, host: row.host) }
                            WakeNotice(id: row.id)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
            if !newDiscoveries.isEmpty {
                Section("On this network") {
                    ForEach(newDiscoveries) { found in
                        Button { add(address: found.address) } label: {
                            HostRow(name: found.name, address: found.address, status: "Not paired",
                                    isPaired: false, isOffline: false, isBusy: busyAddress == found.address)
                        }
                        .disabled(busyAddress != nil)
                    }
                }
            }
        }
    }

    static let permissionText =
        "Allow Local Network for Pocket Rig in Settings to find your PC automatically. You can still add it by address."

    // MARK: Actions

    /// Checks every paired PC that Wake PC could help, so an offline one shows its button. Same 30-second
    /// beat as the cover; skipped for sample rows.
    private func statusLoop() async {
        #if DEBUG
        if DebugLaunchOptions.flag("hostListDemo") { return }
        #endif
        while !Task.isCancelled {
            for host in hosts where host.isPaired && host.macAddress.map(WakeOnLAN.isValidMAC) == true {
                await model.probeHost(host, checkHelper: false)
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func open(_ host: Host) {
        UISelectionFeedbackGenerator().selectionChanged()
        model.path.append(host.isPaired ? .apps(serverUniqueID: host.serverUniqueID)
                                        : .pair(serverUniqueID: host.serverUniqueID))
    }

    private func add(address: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, busyAddress == nil else { return }
        busyAddress = address
        Task {
            defer { busyAddress = nil }
            do {
                let host = try await model.addHost(address: address, context: context)
                open(host)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = AppModel.message(for: error)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where hosts.indices.contains(index) { context.delete(hosts[index]) }
        do {
            try context.save()
        } catch {
            dataLog.error("Deleting host failed: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            deleteFailed = true
        }
    }
}

private struct HostRow: View {
    let name: String
    let address: String
    let status: String
    let isPaired: Bool
    let isOffline: Bool
    let isBusy: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Big text: one column, so the name, address and status each get the full width
                // (side by side they were cut to "Gam…", "192.1…" and "…" on an iPhone SE).
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline).foregroundStyle(.primary)
                    Text(address).font(.subheadline).foregroundStyle(.secondary)
                    statusView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(address).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    statusView.lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusView: some View {
        if isBusy {
            ProgressView()
        } else {
            Label(status, systemImage: isOffline ? "power" : (isPaired ? "checkmark.seal.fill" : "lock.open"))
                .font(.subheadline)
                .foregroundStyle(isPaired && !isOffline ? .green : .secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}
