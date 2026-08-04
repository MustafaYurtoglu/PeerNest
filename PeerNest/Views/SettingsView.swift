import AppKit
import SwiftUI

struct PeerNestSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    let appState: AppState
    @Bindable var preferences: PreferencesStore
    @Bindable var launchAtLogin: LaunchAtLoginManager
    let lifecycle: AppLifecycleCoordinator
    let mainWindowCoordinator: MainWindowCoordinator

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image("PeerNestBrand")
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .accessibilityLabel("PeerNest logo")
                VStack(alignment: .leading, spacing: 1) {
                    Text("PeerNest").font(.headline)
                    Text("Settings").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            TabView {
                general
                    .tabItem { Label("General", systemImage: "gear") }
                sync
                    .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                recovery
                    .tabItem { Label("Recovery", systemImage: "clock.arrow.circlepath") }
                notifications
                    .tabItem { Label("Notifications", systemImage: "bell") }
                finder
                    .tabItem { Label("Finder", systemImage: "folder") }
                advanced
                    .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            }
        }
        .padding(12)
        .frame(width: 640, height: 480)
        .background(PeerNestWindowBridge(role: .auxiliary, coordinator: mainWindowCoordinator))
    }

    private var general: some View {
        Form {
            Toggle("Launch PeerNest at Login", isOn: Binding(
                get: { preferences.launchAtLoginIntent },
                set: {
                    preferences.launchAtLoginIntent = $0
                    launchAtLogin.setEnabled($0)
                }
            ))
            LabeledContent("Login item status", value: launchAtLogin.state.title)
            if launchAtLogin.state == .requiresApproval {
                Text("Approve PeerNest in System Settings › General › Login Items.")
                    .foregroundStyle(.secondary)
            }
            Toggle("Start services automatically on launch", isOn: $preferences.startServicesAutomatically)
            Button("Show Onboarding") { NotificationCenter.default.post(name: .showPeerNestOnboarding, object: nil) }
        }
        .formStyle(.grouped)
    }

    private var sync: some View {
        Form {
            Toggle("Pause all synchronization", isOn: Binding(
                get: { appState.isSynchronizationPaused },
                set: { lifecycle.appState.setAllSynchronizationPaused($0) }
            ))
            LabeledContent("Conflict behavior", value: "Preserve both versions")
            LabeledContent("Ignored metadata", value: "PeerNest internal files")
            LabeledContent("Default invitation access", value: "Read & Write")
        }.formStyle(.grouped)
    }

    private var recovery: some View {
        Form {
            LabeledContent("Trash retention", value: "\(appState.retentionPolicy.trashRetentionDays) days")
            LabeledContent("Version retention", value: "\(appState.retentionPolicy.versionRetentionDays) days")
            LabeledContent("Maximum versions per file", value: "\(appState.retentionPolicy.maximumVersionsPerFile)")
            LabeledContent("Maximum recovery storage", value: ByteCountFormatter.string(fromByteCount: appState.retentionPolicy.maximumRecoveryBytes, countStyle: .file))
            Button("Open Sync & Recovery") {
                appState.selectRecoveryCenter()
                lifecycle.showMainWindow {
                    openWindow(id: MainWindowCoordinator.mainSceneID)
                }
            }
        }.formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            Toggle("Conflicts", isOn: $preferences.conflictNotifications)
            Toggle("Permanent operation failures", isOn: $preferences.failureNotifications)
            Toggle("Reconciliation completion", isOn: $preferences.reconciliationNotifications)
            Toggle("Storage warnings", isOn: $preferences.storageNotifications)
            Text("Notification permission is requested only when notification delivery is implemented and initiated by the user.")
                .foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private var finder: some View {
        Form {
            LabeledContent("Extension bundled", value: finderExtensionBundled ? "Yes" : "No")
            LabeledContent("App Group communication", value: appState.lastBadgeSnapshotPublished == nil ? "No recent evidence" : "Snapshot published")
            LabeledContent("Last command", value: formatted(appState.lastFinderCommandReceived))
            LabeledContent("Last badge snapshot", value: formatted(appState.lastBadgeSnapshotPublished))
            LabeledContent("Watched roots", value: String(appState.sharedFolders.count))
            Text("macOS does not expose a reliable public API for exact Finder extension enablement. Enable PeerNest in System Settings › General › Login Items & Extensions › Finder Extensions.")
                .foregroundStyle(.secondary)
            Button("Open Extensions Settings") { openExtensionsSettings() }
        }.formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            LabeledContent("Device", value: appState.peerIdentity.displayName)
            LabeledContent("Fingerprint", value: appState.localSecurityFingerprint ?? "Unavailable")
            LabeledContent("Protocol", value: String(PeerProtocolConstants.version))
            LabeledContent("Network", value: appState.localNetworkState.title)
            Button("Export Sanitized Diagnostics") {
                Task { _ = try? await DiagnosticsExporter.export(appState: appState) }
            }
            #if DEBUG
            Text("Localhost controls are available only in Debug builds.").foregroundStyle(.secondary)
            #endif
        }.formStyle(.grouped)
    }

    private var finderExtensionBundled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let files = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension == "appex" && $0.lastPathComponent.contains("PeerNestFinderExtension") }
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Never observed"
    }

    private func openExtensionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Notification.Name {
    static let showPeerNestOnboarding = Notification.Name("showPeerNestOnboarding")
}
