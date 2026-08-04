import Foundation
import Testing
@testable import PeerNest

@MainActor
struct RuntimeFoundationTests {
    @Test func conflictHasPriorityOverHealthyState() {
        let state = SyncStateAggregator.state(
            isPaused: false,
            latestError: nil,
            unresolvedConflictCount: 1,
            isReconciling: false,
            transferProgress: nil,
            pendingOperationCount: 0,
            isConnected: true,
            hasEnabledFolders: true
        )
        #expect(state == .conflictsNeedAttention)
    }

    @Test func pauseHasHighestStatePriority() {
        let state = SyncStateAggregator.state(
            isPaused: true,
            latestError: "failure",
            unresolvedConflictCount: 2,
            isReconciling: true,
            transferProgress: 0.5,
            pendingOperationCount: 3,
            isConnected: true,
            hasEnabledFolders: true
        )
        #expect(state == .paused)
    }

    @Test func preferencesPersistWithoutSecretKeys() {
        let suiteName = "PeerNest.RuntimeFoundationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.launchAtLoginIntent = true

        let restored = PreferencesStore(defaults: defaults)
        #expect(restored.launchAtLoginIntent)
        let persistedKeys = Array(defaults.persistentDomain(forName: suiteName)?.keys ?? Dictionary<String, Any>().keys)
        #expect(persistedKeys.allSatisfy {
            !$0.localizedCaseInsensitiveContains("private") && !$0.localizedCaseInsensitiveContains("secret")
        })
    }

    @Test func finderSnapshotRoundTripsAndStaleStateIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folderID = UUID()
        let store = try FinderBadgeSnapshotStore(containerURL: root)
        let snapshot = FinderBadgeSnapshot(
            generatedAt: Date(timeIntervalSinceNow: -FinderBadgeSnapshot.maximumAge - 1),
            folders: [FinderFolderBadgeRecord(sharedFolderID: folderID, state: .upToDate, targetedRelativePaths: [:])]
        )
        try store.write(snapshot)
        let loaded = try store.read()
        let restored = try #require(loaded)
        #expect(restored.folders == snapshot.folders)
        #expect(restored.state(for: folderID) == .unknown)
    }

    @Test func folderSnapshotDiffPreservesRenameSourceAsDeletion() {
        let events = FolderWatcher.inferredSnapshotEvents(
            previous: ["old.txt": false, "kept": true, "removed/child.txt": false],
            current: ["renamed.txt": false, "kept": true, "created": true],
            sharedFolderID: UUID(),
            rootURL: URL(fileURLWithPath: "/tmp/PeerNestWatcherDiff", isDirectory: true)
        )

        #expect(events.map(\.relativePath) == ["removed/child.txt", "old.txt", "created", "renamed.txt"])
        #expect(events[0].type == .fileRemoved)
        #expect(events[1].type == .fileRemoved)
        #expect(events[2].type == .folderCreated)
        #expect(events[3].type == .fileCreated)
    }

    @Test func renegotiatedShareReusesPersistedMappingIdentity() {
        let localID = UUID()
        let remoteID = UUID()
        let peerID = UUID()
        let persisted = ShareMapping(
            localSharedFolderID: localID,
            remoteSharedFolderID: remoteID,
            remotePeerID: peerID,
            localRole: .receiver
        )

        let restored = PeerSyncCoordinator.negotiatedMapping(
            existing: persisted,
            localSharedFolderID: localID,
            remoteSharedFolderID: remoteID,
            remotePeerID: peerID,
            accessMode: .readWrite,
            localRole: .owner,
            remoteDisplayName: "Remote"
        )

        #expect(restored.id == persisted.id)
        #expect(restored.localRole == .owner)
    }

    @Test func releaseSecurityFlagsFailClosed() {
        #if DEBUG
        #expect(BuildConfiguration.allowsLocalhostControls)
        #else
        #expect(!BuildConfiguration.allowsLocalhostControls)
        #expect(!BuildConfiguration.allowsPlaintextTransport)
        let configuration = try? DebugLaunchConfiguration.parse([
            "PeerNest", "--instance-id", "deterministic",
            "--debug-share-path", "/tmp/PeerNestIntegration/PeerA",
            "--test-namespace", "peer-a",
            "--integration-auto-start", "--integration-auto-connect"
        ])
        #expect(configuration == DebugLaunchConfiguration())
        #endif
    }
}
