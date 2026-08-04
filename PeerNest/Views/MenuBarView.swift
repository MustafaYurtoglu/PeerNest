import AppKit
import OSLog
import SwiftUI

struct PeerNestMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let appState: AppState
    let lifecycle: AppLifecycleCoordinator
    let quitAction: () -> Void

    init(
        appState: AppState,
        lifecycle: AppLifecycleCoordinator,
        quitAction: @escaping () -> Void
    ) {
        self.appState = appState
        self.lifecycle = lifecycle
        self.quitAction = quitAction
        PeerNestLog.lifecycle.info("MenuBarExtra scene declared with PeerNestMenuBar asset")
    }

    var body: some View {
        Group {
            Button("Open PeerNest") { showMainWindow() }
            Label(appState.overallSyncState.title, systemImage: appState.overallSyncState.systemImage)
            if appState.isSynchronizationPaused {
                Button("Resume All Sync") { lifecycle.resumeSynchronization() }
            } else {
                Button("Pause All Sync") { lifecycle.pauseSynchronization() }
            }
            Divider()
            Button("Shared Folders") { showSharedFolders() }
            Button("Nearby Devices") { showNearbyDevices() }
            Button("Settings") { showSettings() }
            Button("About PeerNest") { showAboutPanel() }
            Divider()
            Button("Quit PeerNest", action: quitAction)
        }
    }

    private func showMainWindow() {
        lifecycle.showMainWindow {
            openWindow(id: MainWindowCoordinator.mainSceneID)
        }
    }

    private func showSharedFolders() {
        if let folderID = appState.selectedSharedFolderID ?? appState.sharedFolders.first?.id {
            appState.select(folderID: folderID)
        }
        showMainWindow()
    }

    private func showNearbyDevices() {
        if appState.selectedNearbyPeer == nil, appState.selectedTrustedPeer == nil {
            if let peer = appState.nearbyPeers.first(where: { $0.availability == .available }) {
                appState.select(nearbyPeerID: peer.id)
            } else if let peer = appState.trustedPeers.first(where: { $0.trustState != .revoked }) {
                appState.select(trustedPeerID: peer.peerID)
            }
        }
        showMainWindow()
    }

    private func showSettings() {
        lifecycle.showSettings {
            openSettings()
        }
    }

    private func showAboutPanel() {
        lifecycle.showAboutPanel()
    }
}

struct PeerNestMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState
    let lifecycle: AppLifecycleCoordinator

    init(appState: AppState, lifecycle: AppLifecycleCoordinator) {
        self.appState = appState
        self.lifecycle = lifecycle
        PeerNestLog.lifecycle.info("Persistent PeerNestMenuBar asset label initialized")
    }

    var body: some View {
        Image("PeerNestMenuBar")
            .renderingMode(.template)
            .accessibilityLabel("PeerNest menu bar icon: \(appState.overallSyncState.title)")
            .onReceive(NotificationCenter.default.publisher(for: .openPeerNestMainWindow)) { _ in
                lifecycle.showMainWindow {
                    openWindow(id: MainWindowCoordinator.mainSceneID)
                }
            }
    }
}
