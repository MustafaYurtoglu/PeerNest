import AppKit
import Foundation

@MainActor
enum DiagnosticsExporter {
    static func export(appState: AppState) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for PeerNest Diagnostics"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let directory = panel.url else { return nil }

        let payload: [String: Any] = [
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "protocolVersion": PeerProtocolConstants.version,
            "overallState": appState.overallSyncState.rawValue,
            "localNetworkState": appState.localNetworkState.title,
            "trustedPeerCount": appState.trustedPeers.count,
            "nearbyPeerCount": appState.nearbyPeers.count,
            "sharedFolderCount": appState.sharedFolders.count,
            "enabledSharedFolderCount": appState.sharedFolders.filter(\.isEnabled).count,
            "pendingOperationCount": appState.pendingOperationCount,
            "journalOperationCount": appState.journalOperations.count,
            "conflictCount": appState.conflicts.count,
            "trashRecordCount": appState.trashRecords.count,
            "storedVersionCount": appState.storedVersions.count,
            "finderCommandObserved": appState.lastFinderCommandReceived != nil,
            "finderSnapshotPublished": appState.lastBadgeSnapshotPublished != nil,
            "sandboxExpected": true,
            "appGroup": PeerNestSharedConfiguration.appGroupIdentifier
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let destination = directory.appendingPathComponent("PeerNest-Diagnostics-\(UUID().uuidString.prefix(8)).json")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
