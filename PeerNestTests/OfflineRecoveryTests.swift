import Foundation
import Testing
@testable import PeerNest

struct OfflineRecoveryTests {
    @Test func queuedOperationSurvivesReload() async throws {
        let fixture = try Fixture()
        let operation = try fixture.journaled(type: .updateFile, path: "note.txt", sequence: 1)
        try await fixture.repository.enqueue(operation)
        let reloaded = try RecoveryRepository(rootURL: fixture.root)
        let restored = await reloaded.operation(id: operation.id)
        #expect(restored?.operationID == operation.operationID)
        #expect(restored?.mappingID == operation.mappingID)
        #expect(restored?.relativeSourcePath == operation.relativeSourcePath)
        #expect(restored?.logicalSequence == operation.logicalSequence)
        #expect(restored?.state == .queued)
        #expect(abs((restored?.createdAt.timeIntervalSince1970 ?? 0) - operation.createdAt.timeIntervalSince1970) < 0.001)
    }

    @Test func stateTransitionsPersist() async throws {
        let fixture = try Fixture()
        let operation = try fixture.journaled(type: .createFile, path: "a.txt", sequence: 1)
        try await fixture.repository.enqueue(operation)
        try await fixture.repository.transition(operationID: operation.id, to: .preparing)
        try await fixture.repository.transition(operationID: operation.id, to: .sending)
        try await fixture.repository.transition(operationID: operation.id, to: .awaitingAcknowledgment)
        try await fixture.repository.transition(operationID: operation.id, to: .completed)
        let reloaded = try RecoveryRepository(rootURL: fixture.root)
        #expect(await reloaded.operation(id: operation.id)?.state == .completed)
    }

    @Test func duplicateOperationIDIsRejected() async throws {
        let fixture = try Fixture()
        let operation = try fixture.journaled(type: .updateFile, path: "a.txt", sequence: 1)
        try await fixture.repository.enqueue(operation)
        await #expect(throws: RecoveryRepository.RepositoryError.duplicateOperationID(operation.id)) {
            try await fixture.repository.enqueue(operation)
        }
    }

    @Test func completedOperationsCompactButPendingDeleteDoesNot() async throws {
        let fixture = try Fixture()
        let old = Date(timeIntervalSince1970: 100)
        let complete = try fixture.journaled(type: .updateFile, path: "a.txt", sequence: 1, createdAt: old)
        let destructive = try fixture.journaled(type: .delete, path: "b.txt", sequence: 2, createdAt: old)
        try await fixture.repository.enqueue(complete)
        try await fixture.repository.enqueue(destructive)
        try await fixture.repository.transition(operationID: complete.id, to: .preparing, at: old)
        try await fixture.repository.transition(operationID: complete.id, to: .sending, at: old)
        try await fixture.repository.transition(operationID: complete.id, to: .awaitingAcknowledgment, at: old)
        try await fixture.repository.transition(operationID: complete.id, to: .completed, at: old)
        #expect(try await fixture.repository.compactCompleted(olderThan: Date()) == 1)
        #expect(await fixture.repository.operation(id: destructive.id) != nil)
    }

    @Test func invalidTerminalTransitionIsRejected() async throws {
        let fixture = try Fixture()
        let operation = try fixture.journaled(type: .updateFile, path: "a", sequence: 1)
        try await fixture.repository.enqueue(operation)
        try await fixture.repository.transition(operationID: operation.id, to: .cancelled)
        await #expect(throws: RecoveryRepository.RepositoryError.invalidTransition(.cancelled, .sending)) {
            try await fixture.repository.transition(operationID: operation.id, to: .sending)
        }
    }

    @Test func repeatedUpdatesCollapseToNewest() throws {
        let fixture = try Fixture()
        let first = try fixture.journaled(type: .updateFile, path: "a", sequence: 1)
        let second = try fixture.journaled(type: .updateFile, path: "a", sequence: 2)
        let result = OperationCoalescer.coalesce([first, second])
        #expect(result.map(\.id) == [second.id])
    }

    @Test func createThenDeleteBecomesNoOp() throws {
        let fixture = try Fixture()
        let create = try fixture.journaled(type: .createFile, path: "a", sequence: 1)
        let delete = try fixture.journaled(type: .delete, path: "a", sequence: 2)
        #expect(OperationCoalescer.coalesce([create, delete]).isEmpty)
    }

    @Test func updateThenDeleteAvoidsContentTransfer() throws {
        let fixture = try Fixture()
        let update = try fixture.journaled(type: .updateFile, path: "a", sequence: 1)
        let delete = try fixture.journaled(type: .delete, path: "a", sequence: 2)
        #expect(OperationCoalescer.coalesce([update, delete]).map(\.operationType) == [.delete])
    }

    @Test func renameChainCollapses() throws {
        let fixture = try Fixture()
        let one = try fixture.journaled(type: .rename, path: "a", destination: "b", sequence: 1)
        let two = try fixture.journaled(type: .rename, path: "b", destination: "c", sequence: 2)
        let result = OperationCoalescer.coalesce([one, two])
        #expect(result.count == 1)
        #expect(result.first?.relativeSourcePath == "a")
        #expect(result.first?.relativeDestinationPath == "c")
    }

    @Test func operationsAcrossMappingsNeverMerge() throws {
        let fixture = try Fixture()
        let one = try fixture.journaled(type: .updateFile, path: "a", sequence: 1)
        let two = try fixture.journaled(type: .updateFile, path: "a", sequence: 2, mappingID: UUID())
        #expect(OperationCoalescer.coalesce([one, two]).count == 2)
    }

    @Test func dependenciesCreateParentsFirstAndDeleteChildrenFirst() throws {
        let fixture = try Fixture()
        let child = try fixture.journaled(type: .createFile, path: "Folder/a", sequence: 2)
        let parent = try fixture.journaled(type: .createDirectory, path: "Folder", sequence: 1)
        #expect(OperationDependencyResolver.ordered([child, parent]).map(\.id) == [parent.id, child.id])
        let deleteParent = try fixture.journaled(type: .delete, path: "Folder", sequence: 3)
        let deleteChild = try fixture.journaled(type: .delete, path: "Folder/a", sequence: 4)
        #expect(OperationDependencyResolver.ordered([deleteParent, deleteChild]).map(\.id) == [deleteChild.id, deleteParent.id])
    }

    @Test func logicalClockPersistsAndMergesRemote() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.repository.nextLogicalClock() == 1)
        #expect(try await fixture.repository.nextLogicalClock(afterRemote: 40) == 41)
        let reloaded = try RecoveryRepository(rootURL: fixture.root)
        #expect(await reloaded.currentLogicalClock() == 41)
    }

    @Test func sameContentDoesNotConflictAndSameBaseDoes() {
        let peerA = UUID(), peerB = UUID(), parent = UUID()
        let local = Self.version(id: UUID(), hash: "same", peer: peerA, sequence: 2, parent: parent)
        let same = Self.version(id: UUID(), hash: "same", peer: peerB, sequence: 2, parent: parent)
        let different = Self.version(id: UUID(), hash: "different", peer: peerB, sequence: 2, parent: parent)
        #expect(FileVersionComparator.compare(local: local, remote: same) == .identical)
        #expect(ConflictDetector.conflictType(local: local, remote: same, remoteOperation: .updateFile) == nil)
        #expect(ConflictDetector.conflictType(local: local, remote: different, remoteOperation: .updateFile) == .concurrentModification)
    }

    @Test func deleteOfExpectedVersionDoesNotCreateDeleteModifyConflict() {
        let version = Self.version(id: UUID(), hash: "same", peer: UUID(), sequence: 2, parent: UUID())
        #expect(PeerSyncCoordinator.incomingConflictType(
            operationType: .delete,
            localVersion: version,
            remoteVersion: version,
            expectedDestinationVersionID: version.versionID
        ) == nil)
        #expect(PeerSyncCoordinator.incomingConflictType(
            operationType: .delete,
            localVersion: version,
            remoteVersion: version,
            expectedDestinationVersionID: UUID()
        ) == .deleteVsModify)
    }

    @Test func identicalIncomingVersionDoesNotConflictWhenExpectedIDIsStale() {
        let version = Self.version(id: UUID(), hash: "same", peer: UUID(), sequence: 2, parent: UUID())
        #expect(PeerSyncCoordinator.incomingConflictType(
            operationType: .updateFile,
            localVersion: version,
            remoteVersion: version,
            expectedDestinationVersionID: UUID()
        ) == nil)
    }

    @Test func conflictNameIsDeterministicPreservesExtensionAndAvoidsCollision() {
        let peer = UUID(), version = UUID()
        let first = ConflictCopyNamer.path(originalPath: "Docs/report.final.pdf", losingPeerName: "Mac/A:1", losingPeerID: peer, versionID: version)
        let again = ConflictCopyNamer.path(originalPath: "Docs/report.final.pdf", losingPeerName: "Mac/A:1", losingPeerID: peer, versionID: version)
        let second = ConflictCopyNamer.path(originalPath: "Docs/report.final.pdf", losingPeerName: "Mac/A:1", losingPeerID: peer, versionID: version, occupiedPaths: [first])
        #expect(first == again)
        #expect(first.hasSuffix(".pdf"))
        #expect(!first.contains("Mac/A:1"))
        #expect(second != first)
    }

    @Test func checkpointHandlesGapsAndOutOfOrderAcknowledgments() async throws {
        let fixture = try Fixture()
        let one = UUID(), two = UUID(), three = UUID()
        try await fixture.repository.acknowledge(operationID: three, logicalSequence: 3, mappingID: fixture.mappingID)
        #expect(await fixture.repository.checkpoint(mappingID: fixture.mappingID).highestContiguousSequence == 0)
        try await fixture.repository.acknowledge(operationID: one, logicalSequence: 1, mappingID: fixture.mappingID)
        #expect(await fixture.repository.checkpoint(mappingID: fixture.mappingID).highestContiguousSequence == 1)
        try await fixture.repository.acknowledge(operationID: two, logicalSequence: 2, mappingID: fixture.mappingID)
        #expect(await fixture.repository.checkpoint(mappingID: fixture.mappingID).highestContiguousSequence == 3)
    }

    @Test func tombstoneStorageIsIdempotent() async throws {
        let fixture = try Fixture()
        var tombstone = Tombstone(
            tombstoneID: UUID(), sharedFolderID: fixture.shareID, mappingID: fixture.mappingID,
            relativePath: "a", deletedVersionID: nil, deletingPeerID: fixture.originPeerID,
            deletedAt: Date(), logicalClock: 1, expirationDate: Date().addingTimeInterval(10),
            restoreState: .active, acknowledgedPeerIDs: [fixture.originPeerID]
        )
        try await fixture.repository.addTombstone(tombstone)
        tombstone.acknowledgedPeerIDs.insert(fixture.destinationPeerID)
        try await fixture.repository.addTombstone(tombstone)
        let stored = await fixture.repository.tombstones(mappingID: fixture.mappingID)
        #expect(stored.count == 1)
        #expect(stored[0].acknowledgedPeerIDs.count == 2)
    }

    @Test func fileMovesToTrashAndRestores() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let source = shareRoot.appendingPathComponent("note.txt")
        try Data("recover me".utf8).write(to: source)
        let manager = PeerNestTrashManager(repository: fixture.repository)
        let record = try await manager.moveToTrash(
            sharedFolderID: fixture.shareID, mappingID: fixture.mappingID, rootURL: shareRoot,
            relativePath: "note.txt", deletingPeerID: fixture.originPeerID, logicalClock: 1
        )
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(await manager.usage() == Int64("recover me".utf8.count))
        let restored = try await manager.restore(record, to: shareRoot)
        #expect(try Data(contentsOf: restored) == Data("recover me".utf8))
    }

    @Test func occupiedTrashRestoreUsesSafeCopyName() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let source = shareRoot.appendingPathComponent("note.txt")
        try Data("old".utf8).write(to: source)
        let manager = PeerNestTrashManager(repository: fixture.repository)
        let record = try await manager.moveToTrash(
            sharedFolderID: fixture.shareID, mappingID: fixture.mappingID, rootURL: shareRoot,
            relativePath: "note.txt", deletingPeerID: fixture.originPeerID, logicalClock: 1
        )
        try Data("new".utf8).write(to: source)
        let restored = try await manager.restore(record, to: shareRoot)
        #expect(restored.lastPathComponent.contains("Restored"))
        #expect(try Data(contentsOf: source) == Data("new".utf8))
    }

    @Test func versionContentDeduplicatesAndRestores() async throws {
        let fixture = try Fixture()
        let source = fixture.root.appendingPathComponent("source")
        try Data("version".utf8).write(to: source)
        let history = VersionHistoryStore(repository: fixture.repository)
        let first = try await history.store(fileURL: source, sharedFolderID: fixture.shareID, relativePath: "a", originatingPeerID: fixture.originPeerID, reason: .remoteUpdate)
        let second = try await history.store(fileURL: source, sharedFolderID: fixture.shareID, relativePath: "a", originatingPeerID: fixture.originPeerID, reason: .conflictResolution)
        #expect(first.contentStorageRelativePath == second.contentStorageRelativePath)
        #expect(await history.usage() == first.size)
        let destination = fixture.root.appendingPathComponent("restored")
        _ = try await history.restore(first, to: destination)
        #expect(try Data(contentsOf: destination) == Data("version".utf8))
    }

    @Test func interruptedTransferPersistsAndResumes() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let data = Data("abcdef".utf8)
        let hashSource = fixture.root.appendingPathComponent("hash")
        try data.write(to: hashSource)
        let hash = try await FileHashing.sha256(of: hashSource)
        let payload = FileTransferStartPayload(
            transferID: UUID(), operationID: UUID(), sourceSharedFolderID: UUID(),
            destinationSharedFolderID: fixture.shareID, sourceRelativePath: "file", destinationRelativePath: "file",
            size: 6, sha256: hash, modificationDate: Date(timeIntervalSince1970: 50),
            mappingID: fixture.mappingID, chunkSize: 3
        )
        let first = FileTransferReceiver(registry: AppliedOperationRegistry(), repository: fixture.repository)
        _ = try await first.start(payload, rootURL: shareRoot)
        try await first.append(FileChunkPayload(transferID: payload.transferID, index: 0, data: Data("abc".utf8), offset: 0))
        await first.suspendAll()
        let second = FileTransferReceiver(registry: AppliedOperationRegistry(), repository: fixture.repository)
        let resume = try await second.start(payload, rootURL: shareRoot)
        #expect(resume.accepted)
        #expect(resume.nextExpectedOffset == 3)
        try await second.append(FileChunkPayload(transferID: payload.transferID, index: 1, data: Data("def".utf8), offset: 3))
        _ = try await second.complete(transferID: payload.transferID)
        #expect(try Data(contentsOf: shareRoot.appendingPathComponent("file")) == data)
        #expect(await fixture.repository.transfer(id: payload.transferID) == nil)
    }

    @Test func changedTransferMetadataRejectsResume() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let transferID = UUID(), operationID = UUID(), modified = Date(timeIntervalSince1970: 10)
        let firstPayload = FileTransferStartPayload(
            transferID: transferID, operationID: operationID, sourceSharedFolderID: UUID(), destinationSharedFolderID: fixture.shareID,
            sourceRelativePath: "file", destinationRelativePath: "file", size: 6, sha256: "old", modificationDate: modified,
            mappingID: fixture.mappingID, chunkSize: 3
        )
        let first = FileTransferReceiver(registry: AppliedOperationRegistry(), repository: fixture.repository)
        _ = try await first.start(firstPayload, rootURL: shareRoot)
        try await first.append(FileChunkPayload(transferID: transferID, index: 0, data: Data("abc".utf8), offset: 0))
        await first.suspendAll()
        let changed = FileTransferStartPayload(
            transferID: transferID, operationID: operationID, sourceSharedFolderID: UUID(), destinationSharedFolderID: fixture.shareID,
            sourceRelativePath: "file", destinationRelativePath: "file", size: 6, sha256: "new", modificationDate: modified,
            mappingID: fixture.mappingID, chunkSize: 3
        )
        let second = FileTransferReceiver(registry: AppliedOperationRegistry(), repository: fixture.repository)
        let resume = try await second.start(changed, rootURL: shareRoot)
        #expect(!resume.accepted)
        #expect(resume.nextExpectedOffset == 0)
    }

    @Test func corruptJournalIsQuarantined() async throws {
        let fixture = try Fixture()
        try Data("not json".utf8).write(to: fixture.root.appendingPathComponent("recovery-v1.json"), options: .atomic)
        let recovered = try RecoveryRepository(rootURL: fixture.root)
        #expect(await recovered.diagnostics().contains { $0.category == "metadata-corruption" })
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(files.contains { $0.hasPrefix("recovery-v1.corrupt-") })
    }

    @Test func startupAuditReportsMissingRecoveryContent() async throws {
        let fixture = try Fixture()
        let missing = StoredFileVersion(
            versionID: UUID(), sharedFolderID: fixture.shareID, relativePath: "a",
            contentStorageRelativePath: "Versions/Blobs/aa/missing", size: 1, contentHash: "missing",
            originatingPeerID: fixture.originPeerID, storedAt: Date(), reason: .remoteUpdate
        )
        try await fixture.repository.addStoredVersion(missing)
        let diagnostics = try await StartupRecoveryCoordinator(repository: fixture.repository).audit()
        #expect(diagnostics.contains { $0.category == "missing-version-content" })
    }

    @Test func directoryTrashMovesRecursivelyAndTraversalIsRejected() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        let nested = shareRoot.appendingPathComponent("Folder/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: shareRoot.appendingPathComponent("Folder/one.txt"))
        try Data("two".utf8).write(to: nested.appendingPathComponent("two.txt"))
        let manager = PeerNestTrashManager(repository: fixture.repository)
        let record = try await manager.moveToTrash(
            sharedFolderID: fixture.shareID, mappingID: fixture.mappingID, rootURL: shareRoot,
            relativePath: "Folder", deletingPeerID: fixture.originPeerID, logicalClock: 1
        )
        #expect(record.itemType == .directory)
        _ = try await manager.restore(record, to: shareRoot)
        #expect(try Data(contentsOf: nested.appendingPathComponent("two.txt")) == Data("two".utf8))
        await #expect(throws: SharedPathValidationError.pathTraversal) {
            try await manager.moveToTrash(
                sharedFolderID: fixture.shareID, mappingID: fixture.mappingID, rootURL: shareRoot,
                relativePath: "../outside", deletingPeerID: fixture.originPeerID, logicalClock: 2
            )
        }
    }

    @Test func unacknowledgedTombstoneIsNotPurged() async throws {
        let fixture = try Fixture()
        let shareRoot = fixture.root.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: shareRoot.appendingPathComponent("old.txt"))
        let trash = PeerNestTrashManager(repository: fixture.repository)
        let oldDate = Date(timeIntervalSince1970: 100)
        let record = try await trash.moveToTrash(
            sharedFolderID: fixture.shareID, mappingID: fixture.mappingID, rootURL: shareRoot,
            relativePath: "old.txt", deletingPeerID: fixture.originPeerID, logicalClock: 1, now: oldDate
        )
        let storage = RecoveryStorageManager(repository: fixture.repository)
        #expect(await storage.cleanupSummary(now: Date()).eligibleTrashItems == 0)
        try await fixture.repository.acknowledgeTombstone(id: record.tombstoneID, peerID: fixture.destinationPeerID)
        #expect(await storage.cleanupSummary(now: Date()).eligibleTrashItems == 1)
    }

    @Test func maximumVersionsPolicyPurgesOldestEligibleFirst() async throws {
        let fixture = try Fixture()
        var policy = RetentionPolicy()
        policy.versionRetentionDays = 10_000
        policy.maximumVersionsPerFile = 2
        try await fixture.repository.setRetentionPolicy(policy)
        let history = VersionHistoryStore(repository: fixture.repository)
        let source = fixture.root.appendingPathComponent("source")
        for index in 0..<3 {
            try Data("version-\(index)".utf8).write(to: source)
            _ = try await history.store(
                fileURL: source, sharedFolderID: fixture.shareID, relativePath: "note.txt",
                originatingPeerID: fixture.originPeerID, reason: .remoteUpdate,
                now: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
        }
        let storage = RecoveryStorageManager(repository: fixture.repository)
        #expect(await storage.cleanupSummary(now: Date(timeIntervalSince1970: 500)).eligibleVersions == 1)
        _ = try await storage.cleanup(now: Date(timeIntervalSince1970: 500))
        let remaining = await fixture.repository.storedVersions(sharedFolderID: fixture.shareID, relativePath: "note.txt")
        #expect(remaining.count == 2)
        #expect(remaining.map(\.storedAt) == [Date(timeIntervalSince1970: 102), Date(timeIntervalSince1970: 101)])
    }

    @Test func activeConflictAndPendingJournalContentAreProtectedFromCleanup() async throws {
        let fixture = try Fixture()
        let old = Date(timeIntervalSince1970: 100)
        let versionID = UUID()
        let hash = "protected-hash"
        let relativeBlob = "Versions/Blobs/pr/protected"
        try await fixture.repository.addStoredVersion(StoredFileVersion(
            versionID: versionID, sharedFolderID: fixture.shareID, relativePath: "a",
            contentStorageRelativePath: relativeBlob, size: 8, contentHash: hash,
            originatingPeerID: fixture.originPeerID, storedAt: old, reason: .conflict
        ))
        let fileVersion = Self.version(id: versionID, hash: hash, peer: fixture.originPeerID, sequence: 1, parent: nil)
        try await fixture.repository.addConflict(ConflictRecord(
            conflictID: UUID(), mappingID: fixture.mappingID, relativePath: "a",
            localVersion: fileVersion, remoteVersion: nil, baseVersion: nil,
            conflictType: .deleteVsModify, detectedAt: old, resolutionState: .unresolved,
            generatedConflictCopyPaths: [], userDecision: nil, diagnosticID: "protected"
        ))
        let operation = try fixture.journaled(type: .updateFile, path: "b", sequence: 2)
        let pending = JournaledSyncOperation(
            operation: try operation.syncOperation(), mappingID: operation.mappingID,
            originPeerID: operation.originPeerID, destinationPeerID: operation.destinationPeerID,
            contentMetadata: JournalContentMetadata(size: 8, contentHash: hash, modificationDate: old, stagingRelativePath: relativeBlob),
            createdAt: old, logicalSequence: operation.logicalSequence
        )
        try await fixture.repository.enqueue(pending)
        let summary = await RecoveryStorageManager(repository: fixture.repository).cleanupSummary(now: Date())
        #expect(summary.eligibleVersions == 0)
    }

    @Test func staleTransferStagingIsRemovedByCleanup() async throws {
        let fixture = try Fixture()
        let transferID = UUID()
        let relative = "Staging/\(transferID.uuidString).partial"
        let url = try await fixture.repository.storedURL(for: relative)
        try Data("partial".utf8).write(to: url)
        try await fixture.repository.saveTransfer(ResumableTransferState(
            transferID: transferID, mappingID: fixture.mappingID, operationID: UUID(),
            totalSize: 100, chunkSize: 10, nextExpectedOffset: 7, nextChunkIndex: 1,
            stagingRelativePath: relative, expectedFinalHash: "hash",
            sourceModificationDate: Date(timeIntervalSince1970: 10),
            expirationDate: Date(timeIntervalSince1970: 20), resumeToken: "token"
        ))
        _ = try await RecoveryStorageManager(repository: fixture.repository).cleanup(now: Date(timeIntervalSince1970: 30))
        #expect(await fixture.repository.transfer(id: transferID) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recoveryCapacityRejectsLargeNewBlob() async throws {
        let fixture = try Fixture()
        let source = fixture.root.deletingLastPathComponent().appendingPathComponent("capacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("content".utf8).write(to: source)
        var policy = RetentionPolicy()
        policy.maximumRecoveryBytes = 1
        policy.minimumFreeDiskBytes = 0
        try await fixture.repository.setRetentionPolicy(policy)
        let history = VersionHistoryStore(repository: fixture.repository)
        await #expect(throws: VersionHistoryStore.HistoryError.insufficientRecoveryCapacity) {
            try await history.store(
                fileURL: source, sharedFolderID: fixture.shareID, relativePath: "a",
                originatingPeerID: fixture.originPeerID, reason: .remoteUpdate
            )
        }
    }

    @Test func reconciliationIsBoundedIdempotentAndCancellable() async throws {
        let fixture = try Fixture()
        let mapping = ShareMapping(
            id: fixture.mappingID, localSharedFolderID: fixture.shareID,
            remoteSharedFolderID: UUID(), remotePeerID: fixture.destinationPeerID
        )
        let operations = try (1...3).map {
            try fixture.journaled(type: .updateFile, path: "\($0)", sequence: UInt64($0))
        }
        let coordinator = ReconciliationCoordinator(batchLimit: 2)
        let checkpoint = await fixture.repository.checkpoint(mappingID: fixture.mappingID)
        let summary = await coordinator.makeSummary(
            mapping: mapping, operations: operations, tombstones: [], checkpoint: checkpoint, logicalClock: 3
        )
        #expect(summary.operations.count == 2)
        #expect(summary.hasMoreOperations)
        let first = await coordinator.operationsMissingFromRemote(local: operations, remoteSummary: summary)
        let repeated = await coordinator.operationsMissingFromRemote(local: operations, remoteSummary: summary)
        #expect(first.map(\.id) == repeated.map(\.id))
        await coordinator.begin(totalItems: 3)
        await coordinator.cancel()
        await #expect(throws: CancellationError.self) {
            try await coordinator.advance(state: .transferring, completed: 1)
        }
    }

    private static func version(id: UUID, hash: String, peer: UUID, sequence: UInt64, parent: UUID?) -> FileVersion {
        FileVersion(
            versionID: id, relativePath: "a", itemType: .file, size: 1,
            modificationDate: Date(), contentHash: hash, originatingPeerID: peer,
            logicalSequence: sequence, parentVersionID: parent, createdAt: Date()
        )
    }

    private struct Fixture {
        let root: URL
        let repository: RecoveryRepository
        let shareID = UUID()
        let mappingID = UUID()
        let originPeerID = UUID()
        let destinationPeerID = UUID()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PeerNest-RecoveryTests-\(UUID().uuidString)", isDirectory: true)
            repository = try RecoveryRepository(rootURL: root)
        }

        func journaled(
            type: SyncOperation.OperationType,
            path: String,
            destination: String? = nil,
            sequence: UInt64,
            mappingID: UUID? = nil,
            createdAt: Date = Date()
        ) throws -> JournaledSyncOperation {
            JournaledSyncOperation(
                operation: try SyncOperation(sharedFolderID: shareID, type: type, relativePath: path, destinationRelativePath: destination),
                mappingID: mappingID ?? self.mappingID,
                originPeerID: originPeerID,
                destinationPeerID: destinationPeerID,
                createdAt: createdAt,
                logicalSequence: sequence
            )
        }
    }
}
