//
//  ReconciliationCoordinator.swift
//  PeerNest
//

import CryptoKit
import Foundation

actor ReconciliationCoordinator {
    private(set) var progress = ReconciliationProgress()
    private var isCancelled = false
    private let batchLimit: Int

    init(batchLimit: Int = 200) {
        self.batchLimit = max(1, min(batchLimit, 500))
    }

    func begin(totalItems: Int) {
        isCancelled = false
        progress = ReconciliationProgress(
            state: .exchangingState,
            completedItems: 0,
            totalItems: totalItems,
            message: "Exchanging recovery checkpoints"
        )
    }

    func cancel() {
        isCancelled = true
        progress.state = .paused
        progress.message = "Reconciliation paused"
    }

    func fail(_ error: Error) {
        progress.state = .failed
        progress.message = error.localizedDescription
    }

    func advance(state: ReconciliationState, completed: Int, message: String? = nil) throws {
        guard !isCancelled else { throw CancellationError() }
        progress.state = state
        progress.completedItems = min(max(completed, 0), max(progress.totalItems, completed))
        progress.message = message
    }

    func complete() throws {
        guard !isCancelled else { throw CancellationError() }
        progress.state = .completed
        progress.completedItems = progress.totalItems
        progress.message = "Reconciliation completed"
    }

    func makeSummary(
        mapping: ShareMapping,
        operations: [JournaledSyncOperation],
        tombstones: [Tombstone],
        checkpoint: MappingCheckpoint,
        logicalClock: UInt64
    ) -> ReconciliationSummaryPayload {
        let sorted = operations.sorted { $0.logicalSequence < $1.logicalSequence }
        let bounded = sorted.prefix(batchLimit).map {
            ReconciliationOperationSummary(
                operationID: $0.operationID,
                logicalSequence: $0.logicalSequence,
                state: $0.state,
                relativePathHash: Self.pathHash($0.relativeSourcePath)
            )
        }
        return ReconciliationSummaryPayload(
            sourceSharedFolderID: mapping.localSharedFolderID,
            destinationSharedFolderID: mapping.remoteSharedFolderID,
            mappingID: mapping.id,
            logicalClock: logicalClock,
            checkpoint: checkpoint,
            operations: Array(bounded),
            tombstones: Array(tombstones.prefix(batchLimit)),
            hasMoreOperations: sorted.count > batchLimit
        )
    }

    func operationsMissingFromRemote(
        local: [JournaledSyncOperation],
        remoteSummary: ReconciliationSummaryPayload
    ) -> [JournaledSyncOperation] {
        let knownIDs = remoteSummary.checkpoint.acknowledgedOperationIDs
            .union(remoteSummary.operations.map(\.operationID))
        return OperationDependencyResolver.ordered(OperationCoalescer.coalesce(local.filter {
            !knownIDs.contains($0.operationID)
                && $0.logicalSequence > remoteSummary.checkpoint.highestContiguousSequence
                && $0.state != .cancelled
                && $0.state != .permanentlyFailed
        }))
    }

    func batch<T>(_ values: [T], startingAt offset: Int) -> ArraySlice<T> {
        guard offset < values.count else { return [] }
        return values[offset..<min(offset + batchLimit, values.count)]
    }

    private nonisolated static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

actor StartupRecoveryCoordinator {
    private let repository: RecoveryRepository
    private let fileManager: FileManager

    init(repository: RecoveryRepository, fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    @discardableResult
    func audit(now: Date = Date()) async throws -> [RecoveryDiagnostic] {
        let document = await repository.snapshot()
        for version in document.versions {
            let url = try await repository.storedURL(for: version.contentStorageRelativePath)
            if !fileManager.fileExists(atPath: url.path) {
                _ = try await repository.addDiagnostic(
                    category: "missing-version-content",
                    message: "Stored content is missing for version \(version.versionID.uuidString)."
                )
            }
        }
        for record in document.trash {
            let url = try await repository.storedURL(for: record.storedRelativePath)
            if !fileManager.fileExists(atPath: url.path) {
                _ = try await repository.addDiagnostic(
                    category: "missing-trash-content",
                    message: "Trash content is missing for tombstone \(record.tombstoneID.uuidString)."
                )
            }
        }
        for transfer in document.resumableTransfers where transfer.expirationDate < now {
            _ = try await repository.addDiagnostic(
                category: "stale-transfer",
                message: "Transfer \(transfer.transferID.uuidString) is expired and eligible for cleanup."
            )
        }
        let knownStoredPaths = Set(document.versions.map(\.contentStorageRelativePath))
            .union(document.trash.map(\.storedRelativePath))
            .union(document.resumableTransfers.map(\.stagingRelativePath))
        if let enumerator = fileManager.enumerator(at: repository.rootURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            let urls = enumerator.compactMap { $0 as? URL }
            for url in urls {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      url != repository.metadataURL,
                      let relative = try? SharedPathValidator.safeRelativePath(from: repository.rootURL, to: url),
                      !knownStoredPaths.contains(relative),
                      !url.lastPathComponent.hasPrefix("recovery-v1.corrupt-") else { continue }
                _ = try await repository.addDiagnostic(
                    category: "orphaned-recovery-content",
                    message: "Unindexed recovery content was preserved as \(relative)."
                )
            }
        }
        return await repository.diagnostics()
    }
}

nonisolated enum RecoveryPersistenceMigrator {
    static let currentSchemaVersion = RecoveryRepositoryDocument.currentSchemaVersion

    static func prepare(rootURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let metadata = rootURL.appendingPathComponent("recovery-v1.json")
        guard fileManager.fileExists(atPath: metadata.path) else { return }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
        let schema = raw?["schemaVersion"] as? Int ?? 0
        guard schema != currentSchemaVersion else { return }
        let backup = rootURL.appendingPathComponent("recovery-before-v\(currentSchemaVersion)-\(UUID().uuidString).json")
        try fileManager.copyItem(at: metadata, to: backup)
        guard schema == 0 else { throw RecoveryRepository.RepositoryError.unsupportedSchema(schema) }
        // Version zero was never shipped. Keeping the backup is safer than guessing at field semantics.
        throw RecoveryRepository.RepositoryError.unsupportedSchema(schema)
    }
}
