//
//  HomeView.swift
//  PeerNest
//

import SwiftUI

struct HomeView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                #if DEBUG
                DebugPeerPanel(appState: appState)
                Divider()
                #endif

                if appState.isRecoveryCenterSelected {
                    RecoveryCenterView(appState: appState)
                } else if let peer = appState.selectedTrustedPeer {
                    TrustedPeerDetailView(appState: appState, peer: peer)
                        .id(peer.peerID)
                } else if let peer = appState.selectedNearbyPeer {
                    NearbyPeerDetailView(appState: appState, peer: peer)
                        .id(peer.id)
                } else if let folder = appState.selectedSharedFolder {
                    SharedFolderDetailView(appState: appState, folder: folder)
                        .id(folder.id)
                } else {
                    emptyDetail
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .overlay(alignment: .top) {
            if let notice = appState.presentedNotice {
                FinderShareNotice(
                    notice: notice,
                    dismiss: appState.dismissPresentedNotice
                )
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.presentedNotice?.id)
        .alert(item: $appState.presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: Binding(
            get: { appState.showsPairingPresentation },
            set: { if !$0 { appState.cancelPairing() } }
        )) {
            PairingSheet(appState: appState)
        }
        .sheet(item: Binding(
            get: { appState.incomingInvitation },
            set: { if $0 == nil { appState.rejectIncomingInvitation() } }
        )) { invitation in
            IncomingInvitationSheet(appState: appState, invitation: invitation)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Button { appState.selectRecoveryCenter() } label: {
                        Label("Sync & Recovery", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                }

                Section("Shared Folders") {
                    ForEach(appState.sharedFolders) { folder in
                        Button { appState.select(folderID: folder.id) } label: {
                            SharedFolderSidebarRow(folder: folder)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Nearby") {
                    let peers = appState.nearbyPeers.filter {
                        $0.availability == .available && $0.pairingStatus != .trusted
                    }
                    if peers.isEmpty {
                        Text("No unpaired devices nearby")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(peers) { peer in
                            Button { appState.select(nearbyPeerID: peer.id) } label: {
                                NearbyPeerSidebarRow(peer: peer)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Trusted") {
                    let peers = appState.trustedPeers.filter { $0.trustState != .revoked }
                    if peers.isEmpty {
                        Text("No trusted devices")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(peers) { peer in
                            Button { appState.select(trustedPeerID: peer.peerID) } label: {
                                TrustedPeerSidebarRow(
                                    peer: peer,
                                    isOnline: appState.isOnline(peer),
                                    isConnected: appState.isConnected(peer)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await appState.addSharedFolder() }
            } label: {
                Label("Add Shared Folder", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240)
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Image("PeerNestBrand")
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityLabel("PeerNest logo")
                Text("No Shared Folders")
            }
        } description: {
            Text("Add a folder here or use “Share with PeerNest” in Finder.")
        } actions: {
            Button("Add Shared Folder") {
                Task { await appState.addSharedFolder() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct FinderShareNotice: View {
    let notice: AppState.PresentedNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .fontWeight(.semibold)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .shadow(radius: 8, y: 3)
    }
}

#if DEBUG
private struct DebugPeerPanel: View {
    @Bindable var appState: AppState

    var body: some View {
        DisclosureGroup("Localhost Synchronization Prototype") {
            VStack(alignment: .leading, spacing: 14) {
                identityGrid
                connectionFields
                controls
                synchronizationStatus
                recentActivity
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var identityGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Local instance").foregroundStyle(.secondary)
                Text(appState.peerIdentity.instanceName)
                Text("Peer ID").foregroundStyle(.secondary)
                Text(appState.peerIdentity.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            }
            GridRow {
                Text("Listener").foregroundStyle(.secondary)
                Text(appState.listeningState.title)
                Text("Handshake").foregroundStyle(.secondary)
                Text(appState.handshakeState.title)
            }
            GridRow {
                Text("Connection").foregroundStyle(.secondary)
                Text(appState.connectionState.title)
                Text("Connected peer").foregroundStyle(.secondary)
                Text(appState.connectedPeer?.displayName ?? "None")
            }
        }
    }

    private var connectionFields: some View {
        HStack {
            TextField("Listen port", text: $appState.debugListeningPort)
                .frame(width: 110)
            TextField("Peer host", text: $appState.debugRemoteHost)
                .frame(minWidth: 160)
            TextField("Peer port", text: $appState.debugRemotePort)
                .frame(width: 110)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var controls: some View {
        HStack {
            Button("Start Listening") { appState.startListening() }
            Button("Connect") { appState.connect() }
            Button("Disconnect") { appState.disconnect() }
                .disabled(appState.connectionState == .disconnected || appState.connectionState == .setup)
            Button("Run Initial Sync") { appState.runInitialSync() }
                .disabled(appState.handshakeState != .ready || appState.shareMapping == nil)
            Spacer()
            if let folder = appState.mappedSharedFolder {
                Button("Reveal Shared Folder") { appState.revealSharedFolder(folder) }
            }
            Button("Clear Activity") { appState.clearSynchronizationActivity() }
                .disabled(appState.synchronizationActivity.isEmpty)
        }
    }

    private var synchronizationStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("Mapped shared folder", value: appState.mappedSharedFolder?.displayName ?? "None")
            LabeledContent("Initial sync", value: appState.initialSyncState.rawValue)
            LabeledContent("Pending operations", value: String(appState.pendingOperationCount))
            if let progress = appState.transferProgress {
                ProgressView(value: progress) {
                    Text("File transfer")
                } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
            }
            if let error = appState.latestSynchronizationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Synchronization Activity").font(.headline)
            if appState.synchronizationActivity.isEmpty {
                Text("No synchronization activity yet.").foregroundStyle(.secondary)
            } else {
                ForEach(appState.synchronizationActivity.prefix(6)) { activity in
                    HStack {
                        Text(activity.timestamp, style: .time).foregroundStyle(.secondary)
                        Text(activity.message).lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
#endif

private struct SharedFolderSidebarRow: View {
    let folder: SharedFolder

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)

            Text(folder.displayName)
                .lineLimit(1)

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .help(folder.syncState.title)
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch folder.syncState {
        case .monitoring: .green
        case .error: .red
        case .unavailable: .orange
        case .idle: .secondary
        }
    }
}

private struct SharedFolderDetailView: View {
    @Bindable var appState: AppState
    let folder: SharedFolder
    @State private var isConfirmingRemoval = false

    private var activity: [FileChangeEvent] {
        appState.activity(for: folder.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                folderInformation
                activitySection
                peerAccessSection
                removalSection
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .confirmationDialog(
            "Stop Sharing \(folder.displayName)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                appState.removeSharedFolder(id: folder.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PeerNest will stop syncing this folder. Your files will not be deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(folder.displayName)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Everything inside this folder is included.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusIndicator(title: folder.syncState.title, color: statusColor)
        }
    }

    private var folderInformation: some View {
        GroupBox("Shared Folder") {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Location") {
                    Text(folder.rootURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                LabeledContent("Access") {
                    Text(folder.accessMode.title)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Monitor this folder",
                    isOn: Binding(
                        get: { folder.isEnabled },
                        set: { appState.setMonitoringEnabled($0, for: folder.id) }
                    )
                )

                HStack {
                    Button("Reveal in Finder") {
                        appState.revealSharedFolder(folder)
                    }

                    Spacer()

                    StatusIndicator(
                        title: appState.syncStatus.title,
                        color: .secondary
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)

                Spacer()

                Button("Clear Activity") {
                    appState.clearActivity(for: folder.id)
                }
                .disabled(activity.isEmpty)
            }

            GroupBox {
                if activity.isEmpty {
                    ContentUnavailableView(
                        "No Recent Activity",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Recursive changes in this shared folder will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(activity) { event in
                            FileChangeEventRow(event: event)
                            if event.id != activity.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var peerAccessSection: some View {
        GroupBox("Peer Access") {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.trustedPeers.contains(where: { $0.trustState == .trusted }) ? "Trusted devices available" : "No paired devices")
                        .fontWeight(.medium)
                    Text(appState.trustedPeers.contains(where: { $0.trustState == .trusted }) ? "Choose a trusted device in the sidebar to send an invitation." : "Pair a device to start syncing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private var removalSection: some View {
        HStack {
            Spacer()
            Button("Stop Sharing", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
    }

    private var statusColor: Color {
        switch folder.syncState {
        case .monitoring: .green
        case .error: .red
        case .unavailable: .orange
        case .idle: .secondary
        }
    }
}

private struct NearbyPeerSidebarRow: View {
    let peer: DiscoveredPeer

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.serviceName).lineLimit(1)
                Text(peer.supportsCurrentProtocol ? peer.interfaceType.rawValue : "Update required")
                    .font(.caption)
                    .foregroundStyle(peer.supportsCurrentProtocol ? Color.secondary : Color.orange)
            }
            Spacer()
            Circle().fill(.green).frame(width: 7, height: 7)
        }
        .padding(.vertical, 3)
    }
}

private struct TrustedPeerSidebarRow: View {
    let peer: TrustedPeer
    let isOnline: Bool
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: peer.trustState == .identityChanged ? "exclamationmark.shield" : "checkmark.shield")
                .foregroundStyle(peer.trustState == .identityChanged ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.displayName).lineLimit(1)
                Text(isConnected ? "Connected" : isOnline ? "Online" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(isConnected ? .green : isOnline ? .orange : .secondary)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 3)
    }
}

private struct NearbyPeerDetailView: View {
    @Bindable var appState: AppState
    let peer: DiscoveredPeer

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "desktopcomputer.and.macbook")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text(peer.serviceName)
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Nearby on \(peer.interfaceType.rawValue)")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !peer.supportsCurrentProtocol {
                Label("This Mac uses an incompatible PeerNest protocol version.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if peer.pairingStatus == .identityChanged {
                Label("The saved identity for this device has changed.", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            Button("Pair") { appState.pair(with: peer) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!peer.supportsCurrentProtocol || peer.pairingStatus != .available)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct TrustedPeerDetailView: View {
    @Bindable var appState: AppState
    let peer: TrustedPeer
    @State private var selectedFolderID: UUID?
    @State private var invitationAccessMode: SharedFolderAccessMode = .readWrite
    @State private var isConfirmingForget = false

    private var peerMappings: [ShareMapping] {
        appState.shareMappings.filter { $0.remotePeerID == peer.peerID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if peer.trustState == .identityChanged { identityWarning }
                security
                connection
                sharing
                acceptedShares
                HStack {
                    Spacer()
                    Button("Forget Device", role: .destructive) { isConfirmingForget = true }
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task { selectedFolderID = selectedFolderID ?? appState.sharedFolders.first?.id }
        .confirmationDialog(
            "Forget \(peer.displayName)?",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget Device", role: .destructive) { appState.forget(peer: peer) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PeerNest will stop trusting this device. Your local files will not be deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(peer.displayName).font(.largeTitle).fontWeight(.semibold)
                Text(appState.isConnected(peer) ? "Authenticated encrypted connection" : appState.isOnline(peer) ? "Available nearby" : "Offline")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            StatusIndicator(
                title: appState.isConnected(peer) ? "Connected" : appState.isOnline(peer) ? "Online" : "Offline",
                color: appState.isConnected(peer) ? .green : appState.isOnline(peer) ? .orange : .secondary
            )
        }
    }

    private var identityWarning: some View {
        GroupBox {
            HStack {
                Label(
                    "This device presented a different security identity. Connections are blocked until you explicitly pair it again.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                Spacer()
                Button("Pair New Identity…") { appState.pairNewIdentity(for: peer) }
                    .disabled(!appState.isOnline(peer))
            }
            .padding(6)
        }
    }

    private var security: some View {
        GroupBox("Trust & Identity") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Trusted since") { Text(peer.pairedAt, style: .date).foregroundStyle(.secondary) }
                LabeledContent("Last connected") {
                    if let date = peer.lastConnectedAt { Text(date, style: .relative).foregroundStyle(.secondary) }
                    else { Text("Never").foregroundStyle(.secondary) }
                }
                LabeledContent("Fingerprint") {
                    Text(peer.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Connect automatically when nearby", isOn: Binding(
                    get: { peer.autoConnectEnabled },
                    set: { appState.setAutoConnect($0, for: peer.peerID) }
                ))
                .disabled(peer.trustState != .trusted)
            }
            .padding(.vertical, 8)
        }
    }

    private var connection: some View {
        GroupBox("Connection") {
            HStack {
                Text("Normal synchronization traffic is encrypted and authenticated to this fingerprint.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if appState.isConnected(peer) {
                    Button("Disconnect") { appState.disconnect(from: peer) }
                } else {
                    Button("Connect") { appState.connect(to: peer) }
                        .disabled(!appState.isOnline(peer) || peer.trustState != .trusted)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var sharing: some View {
        GroupBox("Share a Folder") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The other Mac must explicitly choose a destination and accept the invitation.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Folder", selection: $selectedFolderID) {
                        Text("Select a folder").tag(UUID?.none)
                        ForEach(appState.sharedFolders) { folder in
                            Text(folder.displayName).tag(Optional(folder.id))
                        }
                    }
                    Picker("Access", selection: $invitationAccessMode) {
                        Text("Read & Write").tag(SharedFolderAccessMode.readWrite)
                        Text("Read Only").tag(SharedFolderAccessMode.readOnly)
                    }
                    Button("Send Invitation") {
                        guard let selectedFolderID else { return }
                        appState.sendInvitation(folderID: selectedFolderID, to: peer.peerID, accessMode: invitationAccessMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFolderID == nil || !appState.isConnected(peer))
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var acceptedShares: some View {
        GroupBox("Accepted Shares") {
            if peerMappings.isEmpty {
                ContentUnavailableView(
                    "No Accepted Shares",
                    systemImage: "folder.badge.person.crop",
                    description: Text("Accepted folder invitations will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 0) {
                    ForEach(peerMappings) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mapping.remoteDisplayName ?? appState.sharedFolders.first(where: { $0.id == mapping.localSharedFolderID })?.displayName ?? "Shared Folder")
                                    .fontWeight(.medium)
                                Text("\(mapping.accessMode.title) · \(mapping.localRole == .owner ? "Owner" : "Receiver")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Local: \(appState.sharedFolders.first(where: { $0.id == mapping.localSharedFolderID })?.displayName ?? "Unavailable") · \(mapping.isEnabled ? (appState.isConnected(peer) ? "Ready" : "Peer offline") : "Paused")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if mapping.accessMode == .readOnly && mapping.localRole == .receiver {
                                    Text("Local edits are not sent and may be replaced by owner updates.")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button(mapping.isEnabled ? "Pause" : "Resume") {
                                appState.setMappingEnabled(!mapping.isEnabled, mappingID: mapping.id)
                            }
                            Button("Initial Sync") { appState.runInitialSync(mappingID: mapping.id) }
                                .disabled(!mapping.isEnabled || !appState.isConnected(peer))
                            Button("Stop", role: .destructive) { appState.stopSynchronization(mappingID: mapping.id) }
                                .disabled(!mapping.isEnabled)
                        }
                        .padding(.vertical, 10)
                        if mapping.id != peerMappings.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct PairingSheet: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Pair with \(appState.pairingPeerDisplayName ?? "Nearby Mac")")
                .font(.title2).fontWeight(.semibold)
            content
            if let activity = appState.pairingActivities.first {
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(width: 460)
        .frame(minHeight: 330)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.pairingState {
        case .requesting:
            ProgressView("Sending pairing request…")
            Button("Cancel", role: .cancel) { appState.cancelPairing() }
        case .awaitingRemoteApproval:
            Text("This Mac wants to pair. Approve only if you recognize the device name.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Reject", role: .destructive) { appState.rejectPairing() }
                Button("Approve") { appState.approveIncomingPairing() }.buttonStyle(.borderedProminent)
            }
        case let .awaitingCodeConfirmation(code, expiresAt):
            Text("Confirm this exact code is shown on both Macs. The code is derived locally and is never sent.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Text("Expires")
                Text(expiresAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Reject", role: .destructive) { appState.rejectPairing() }
                Button("Confirm Codes Match") { appState.confirmPairingCode() }.buttonStyle(.borderedProminent)
            }
        case .confirming:
            ProgressView("Waiting for confirmation on the other Mac…")
            Button("Cancel", role: .cancel) { appState.cancelPairing() }
        case .paired:
            Label("Device trusted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Done") { appState.cancelPairing() }
        case .rejected:
            Text("Pairing was rejected.").foregroundStyle(.secondary)
            Button("Close") { appState.cancelPairing() }
        case .expired:
            Text("The pairing request expired.").foregroundStyle(.secondary)
            Button("Close") { appState.cancelPairing() }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Close") { appState.cancelPairing() }
        case .idle:
            EmptyView()
        }
    }
}

private struct IncomingInvitationSheet: View {
    @Bindable var appState: AppState
    let invitation: ShareInvitation

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Folder Invitation", systemImage: "folder.badge.plus")
                .font(.title2).fontWeight(.semibold)
            Text("\(appState.connectedPeer?.displayName ?? "A trusted device") wants to share “\(invitation.displayName)”.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("Access").foregroundStyle(.secondary); Text(invitation.accessMode.title) }
                if let count = invitation.approximateItemCount {
                    GridRow { Text("Items").foregroundStyle(.secondary); Text(count.formatted()) }
                }
                if let size = invitation.approximateTotalSize {
                    GridRow { Text("Approximate size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                }
            }
            Text("Choose a local destination folder before accepting. PeerNest does not reveal either Mac’s absolute path to the other device.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Reject", role: .destructive) { appState.rejectIncomingInvitation() }
                Button("Choose Destination and Accept") {
                    Task { await appState.acceptIncomingInvitation() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

private struct StatusIndicator: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FileChangeEventRow: View {
    let event: FileChangeEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.title)
                    .fontWeight(.medium)
                Text(event.relativePath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
    }
}

#Preview {
    HomeView(appState: AppState())
}
