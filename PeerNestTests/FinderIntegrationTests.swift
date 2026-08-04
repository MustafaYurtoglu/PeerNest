import Foundation
import Testing
@testable import PeerNest

@MainActor
struct FinderIntegrationTests {
    @Test func desktopFolderProducesShareActionAndIsInHomeScope() throws {
        try withFixture { fixture in
            let desktop = fixture.root.appendingPathComponent("Desktop", isDirectory: true)
            let folder = desktop.appendingPathComponent("PeerNestFinderTest", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            #expect(FinderContextMenuPolicy.actions(for: [folder], sharedFolders: []) == [.shareFolder])

            let scope = FinderDirectoryScope.monitoredURLs(
                homeDirectory: fixture.root,
                sharedFolders: []
            )
            #expect(scope.contains(SharedPathValidator.canonicalURL(fixture.root)))
            #expect(scope.allSatisfy { $0.path != "/" })
            #expect(scope.contains { SharedPathValidator.contains(root: $0, candidate: folder) })
        }
    }

    @Test func fileAndMultipleSelectionsProduceNoActions() throws {
        try withFixture { fixture in
            let folder = try fixture.makeDirectory("Folder")
            let second = try fixture.makeDirectory("Second")
            let file = fixture.root.appendingPathComponent("file.txt")
            try Data("test".utf8).write(to: file)

            #expect(FinderContextMenuPolicy.actions(for: [file], sharedFolders: []).isEmpty)
            #expect(FinderContextMenuPolicy.actions(for: [folder, second], sharedFolders: []).isEmpty)
        }
    }

    @Test func existingRootAndDescendantProduceExpectedActions() throws {
        try withFixture { fixture in
            let root = try fixture.makeDirectory("Shared")
            let child = try fixture.makeDirectory("Shared/Nested")
            let record = fixture.record(rootURL: root)

            #expect(FinderContextMenuPolicy.actions(for: [root], sharedFolders: [record]) == [
                .showInApp,
                .stopSharing
            ])
            #expect(FinderContextMenuPolicy.actions(for: [child], sharedFolders: [record]) == [
                .showSharedFolderInApp(rootURL: SharedPathValidator.canonicalURL(root))
            ])
        }
    }

    @Test func siblingAndPrefixLookalikeAreNotDescendants() throws {
        try withFixture { fixture in
            let root = try fixture.makeDirectory("Folder")
            let sibling = try fixture.makeDirectory("Sibling")
            let prefixLookalike = try fixture.makeDirectory("Folder2")
            let record = fixture.record(rootURL: root)

            #expect(FinderContextMenuPolicy.actions(for: [sibling], sharedFolders: [record]) == [.shareFolder])
            #expect(FinderContextMenuPolicy.actions(for: [prefixLookalike], sharedFolders: [record]) == [.shareFolder])
            #expect(!SharedPathValidator.contains(root: root, candidate: prefixLookalike))
        }
    }

    @Test func parentOverlapAndInternalStorageAreRejected() throws {
        try withFixture { fixture in
            let parent = try fixture.makeDirectory("Parent")
            let sharedChild = try fixture.makeDirectory("Parent/AlreadyShared")
            let internalFolder = try fixture.makeDirectory(".peernest/cache")
            let record = fixture.record(rootURL: sharedChild)

            #expect(FinderContextMenuPolicy.actions(for: [parent], sharedFolders: [record]).isEmpty)
            #expect(FinderContextMenuPolicy.actions(for: [internalFolder], sharedFolders: []).isEmpty)
        }
    }

    @Test func sharedStateSnapshotRoundTrips() throws {
        try withFixture { fixture in
            let shared = try fixture.makeDirectory("Shared")
            let record = fixture.record(rootURL: shared, state: .syncing)
            let snapshot = FinderSharedStateSnapshot(folders: [record])
            let store = try FinderSharedStateSnapshotStore(containerURL: fixture.root)

            try store.write(snapshot)
            let loaded = try store.read()
            let restored = try #require(loaded)
            #expect(restored == snapshot)
            #expect(restored.folders.first?.rootURL == SharedPathValidator.canonicalURL(shared))
        }
    }

    @Test func corruptSnapshotFailsClosedWithoutThrowing() throws {
        try withFixture { fixture in
            let store = try FinderSharedStateSnapshotStore(containerURL: fixture.root)
            let url = fixture.root.appendingPathComponent("FinderSharedStateSnapshot.plist")
            try Data("not a property list".utf8).write(to: url)

            guard case .corrupt = store.readDefensively() else {
                Issue.record("Expected a corrupt snapshot result")
                return
            }
            let folder = try fixture.makeDirectory("Candidate")
            #expect(FinderContextMenuPolicy.actions(
                for: [folder],
                sharedFolders: [],
                snapshotIsReliable: false
            ).isEmpty)
        }
    }

    @Test func staleSnapshotPreservesPathClassificationButUsesUnknownBadge() throws {
        try withFixture { fixture in
            let root = try fixture.makeDirectory("Shared")
            let generatedAt = Date(timeIntervalSinceNow: -FinderSharedStateSnapshot.maximumAge - 1)
            let record = FinderSharedFolderRecord(
                id: UUID(),
                rootURL: root,
                isEnabled: true,
                state: .upToDate,
                updatedAt: generatedAt
            )
            let snapshot = FinderSharedStateSnapshot(generatedAt: generatedAt, folders: [record])
            let store = try FinderSharedStateSnapshotStore(containerURL: fixture.root)
            try store.write(snapshot)

            guard case let .valid(restored) = store.readDefensively() else {
                Issue.record("Expected a readable stale snapshot")
                return
            }
            #expect(restored.isStale())
            #expect(restored.badgeState(for: record.id) == .unknown)
            #expect(FinderContextMenuPolicy.actions(for: [root], sharedFolders: restored.folders) == [
                .showInApp,
                .stopSharing
            ])
        }
    }

    @Test func finderCommandsAreAtomicAndDuplicateIDsAppearOnce() throws {
        try withFixture { fixture in
            let queue = try FinderCommandQueue(containerURL: fixture.root)
            let selected = try fixture.makeDirectory("Selected")
            let id = UUID()
            let first = FinderCommand(id: id, type: .shareFolder, selectedURL: selected, createdAt: Date())
            let duplicate = FinderCommand(
                id: id,
                type: .shareFolder,
                selectedURL: selected,
                createdAt: first.createdAt.addingTimeInterval(1)
            )

            try queue.enqueue(first)
            try queue.enqueue(duplicate)
            let commandFiles = try FileManager.default.contentsOfDirectory(
                at: fixture.root.appendingPathComponent("FinderCommands", isDirectory: true),
                includingPropertiesForKeys: nil
            )
            #expect(commandFiles.count == 2)
            #expect(commandFiles.allSatisfy { $0.pathExtension == "command" })
            #expect(try queue.pendingCommands().map(\.id) == [id])

            try queue.markConsumed(first)
            #expect(try queue.pendingCommands().isEmpty)
        }
    }

    @Test func shareCommandAddsPersistsAndMonitorsFolderWithoutPeer() async throws {
        try await withFixture { fixture in
            let defaultsSuite = "PeerNest.FinderShareFlowTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            defer { defaults.removePersistentDomain(forName: defaultsSuite) }

            let persistence = SharedFolderPersistenceService(defaults: defaults)
            let manager = SharedFolderManager(
                bookmarkStore: DebugUnscopedBookmarkStore(),
                persistence: persistence
            )
            defer { manager.stopAll() }

            let queue = try FinderCommandQueue(containerURL: fixture.root)
            let selectedFolder = try fixture.makeDirectory("Selected")
            let bookmarkData = Data(selectedFolder.standardizedFileURL.path.utf8)
            try queue.enqueue(FinderCommand(
                type: .shareFolder,
                selectedURL: selectedFolder,
                bookmarkData: bookmarkData
            ))

            let appState = AppState(
                folderSelectionService: FolderSelectionService(),
                sharedFolderManager: manager,
                finderCommandQueue: queue
            )
            await appState.processPendingFinderCommands()

            let folder = try #require(appState.sharedFolders.first)
            #expect(appState.sharedFolders.count == 1)
            #expect(SharedPathValidator.isSameLocation(folder.rootURL, selectedFolder))
            #expect(folder.isEnabled)
            #expect(folder.syncState == .monitoring)
            #expect(appState.selectedSharedFolderID == folder.id)
            #expect(appState.presentedNotice?.title == "Folder Ready")
            #expect(appState.presentedNotice?.message.contains("Pair a nearby Mac") == true)
            #expect(try persistence.load().count == 1)
            #expect(try queue.pendingCommands().isEmpty)
        }
    }

    @Test func showAndStopCommandsSelectRootAndNeverDeleteUserFiles() async throws {
        try await withFixture { fixture in
            let defaultsSuite = "PeerNest.FinderMenuCommandTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            defer { defaults.removePersistentDomain(forName: defaultsSuite) }

            let persistence = SharedFolderPersistenceService(defaults: defaults)
            let manager = SharedFolderManager(
                bookmarkStore: DebugUnscopedBookmarkStore(),
                persistence: persistence
            )
            defer { manager.stopAll() }

            let queue = try FinderCommandQueue(containerURL: fixture.root)
            let appState = AppState(
                folderSelectionService: FolderSelectionService(),
                sharedFolderManager: manager,
                finderCommandQueue: queue
            )

            let root = try fixture.makeDirectory("Shared")
            let nested = try fixture.makeDirectory("Shared/Nested")
            let userFile = nested.appendingPathComponent("keep-me.txt")
            try Data("user data".utf8).write(to: userFile)
            let folder = try manager.addFolder(at: root)

            var windowRequestCount = 0
            appState.onMainWindowRequested = { windowRequestCount += 1 }
            try queue.enqueue(FinderCommand(type: .showInApp, selectedURL: nested))
            await appState.processPendingFinderCommands()

            #expect(windowRequestCount == 1)
            #expect(appState.selectedSharedFolderID == folder.id)

            try queue.enqueue(FinderCommand(type: .stopSharing, selectedURL: root))
            await appState.processPendingFinderCommands()

            #expect(windowRequestCount == 2)
            #expect(appState.sharedFolders.isEmpty)
            #expect(try persistence.load().isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.path))
            #expect(FileManager.default.fileExists(atPath: userFile.path))
        }
    }

    @Test func normalizedPathsCompareByComponents() throws {
        try withFixture { fixture in
            let folder = try fixture.makeDirectory("Folder")
            let alternate = fixture.root
                .appendingPathComponent("Unused")
                .appendingPathComponent("..")
                .appendingPathComponent("Folder", isDirectory: true)
            #expect(SharedPathValidator.isSameLocation(folder, alternate))
        }
    }

    private func withFixture(_ body: (FinderFixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNestFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(FinderFixture(root: root))
    }

    private func withFixture(_ body: (FinderFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNestFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(FinderFixture(root: root))
    }
}

private struct FinderFixture {
    let root: URL

    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func record(
        rootURL: URL,
        state: FinderBadgeState = .upToDate
    ) -> FinderSharedFolderRecord {
        FinderSharedFolderRecord(
            id: UUID(),
            rootURL: rootURL,
            isEnabled: true,
            state: state
        )
    }
}
