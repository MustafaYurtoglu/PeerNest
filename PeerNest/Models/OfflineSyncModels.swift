//
//  OfflineSyncModels.swift
//  PeerNest
//

import Foundation

nonisolated enum JournalOperationState: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case waitingForPeer
    case sending
    case awaitingAcknowledgment
    case completed
    case retryScheduled
    case conflicted
    case permanentlyFailed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .conflicted, .permanentlyFailed, .cancelled: true
        default: false
        }
    }
}

/// Product-facing name retained as an alias so the recovery repository remains
/// the single journal implementation.
typealias OperationJournalState = JournalOperationState

nonisolated enum JournalErrorCategory: String, Codable, Sendable {
    case connectivity
    case authentication
    case authorization
    case sourceUnavailable
    case diskFull
    case integrity
    case protocolFailure
    case conflict
    case unknown
}

nonisolated struct JournalContentMetadata: Codable, Equatable, Sendable {
    let size: Int64
    let contentHash: String?
    let modificationDate: Date?
    let stagingRelativePath: String?
}

nonisolated struct JournaledSyncOperation: Codable, Identifiable, Equatable, Sendable {
    let operationID: UUID
    let sharedFolderID: UUID
    let mappingID: UUID
    let originPeerID: UUID
    let destinationPeerID: UUID
    let operationType: SyncOperation.OperationType
    let relativeSourcePath: String
    let relativeDestinationPath: String?
    let expectedSourceVersion: UUID?
    let expectedDestinationVersion: UUID?
    let contentMetadata: JournalContentMetadata?
    let createdAt: Date
    var updatedAt: Date
    var retryCount: Int
    var state: JournalOperationState
    var lastErrorCategory: JournalErrorCategory?
    var dependencyOperationIDs: [UUID]
    let isDestructive: Bool
    let logicalSequence: UInt64

    var id: UUID { operationID }

    init(
        operation: SyncOperation,
        mappingID: UUID,
        originPeerID: UUID,
        destinationPeerID: UUID,
        expectedSourceVersion: UUID? = nil,
        expectedDestinationVersion: UUID? = nil,
        contentMetadata: JournalContentMetadata? = nil,
        createdAt: Date = Date(),
        state: JournalOperationState = .queued,
        dependencyOperationIDs: [UUID] = [],
        logicalSequence: UInt64
    ) {
        operationID = operation.id
        sharedFolderID = operation.sharedFolderID
        self.mappingID = mappingID
        self.originPeerID = originPeerID
        self.destinationPeerID = destinationPeerID
        operationType = operation.type
        relativeSourcePath = operation.relativePath
        relativeDestinationPath = operation.destinationRelativePath
        self.expectedSourceVersion = expectedSourceVersion
        self.expectedDestinationVersion = expectedDestinationVersion
        self.contentMetadata = contentMetadata
        self.createdAt = createdAt
        updatedAt = createdAt
        retryCount = 0
        self.state = state
        lastErrorCategory = nil
        self.dependencyOperationIDs = dependencyOperationIDs
        isDestructive = operation.type == .delete
        self.logicalSequence = logicalSequence
    }

    func syncOperation() throws -> SyncOperation {
        try SyncOperation(
            id: operationID,
            sharedFolderID: sharedFolderID,
            type: operationType,
            relativePath: relativeSourcePath,
            destinationRelativePath: relativeDestinationPath
        )
    }
}

nonisolated struct FileVersion: Codable, Identifiable, Equatable, Sendable {
    let versionID: UUID
    let relativePath: String
    let itemType: SyncManifestEntry.ItemType
    let size: Int64
    let modificationDate: Date
    let contentHash: String?
    let originatingPeerID: UUID
    let logicalSequence: UInt64
    let parentVersionID: UUID?
    let createdAt: Date

    var id: UUID { versionID }
}

nonisolated enum FileVersionRelationship: String, Codable, Sendable {
    case identical
    case localDescendsFromRemote
    case remoteDescendsFromLocal
    case concurrent
}

nonisolated enum ConflictType: String, Codable, CaseIterable, Sendable {
    case concurrentModification
    case deleteVsModify
    case renameVsRename
    case createVsCreate
    case fileVsDirectory
    case destinationOccupied
    case unsupportedCase
}

nonisolated enum ConflictResolutionState: String, Codable, Sendable {
    case unresolved
    case keepBoth
    case keptLocal
    case keptRemote
    case dismissed
}

nonisolated struct ConflictRecord: Codable, Identifiable, Equatable, Sendable {
    let conflictID: UUID
    let mappingID: UUID
    let relativePath: String
    let localVersion: FileVersion?
    let remoteVersion: FileVersion?
    let baseVersion: FileVersion?
    let conflictType: ConflictType
    let detectedAt: Date
    var resolutionState: ConflictResolutionState
    var generatedConflictCopyPaths: [String]
    var userDecision: ConflictResolutionState?
    let diagnosticID: String

    var id: UUID { conflictID }
}

nonisolated enum TombstoneRestoreState: String, Codable, Sendable {
    case active
    case restored
    case purged
}

nonisolated struct Tombstone: Codable, Identifiable, Equatable, Sendable {
    let tombstoneID: UUID
    let sharedFolderID: UUID
    let mappingID: UUID
    let relativePath: String
    let deletedVersionID: UUID?
    let deletingPeerID: UUID
    let deletedAt: Date
    let logicalClock: UInt64
    let expirationDate: Date?
    var restoreState: TombstoneRestoreState
    var acknowledgedPeerIDs: Set<UUID>

    var id: UUID { tombstoneID }
}

nonisolated enum VersionHistoryReason: String, Codable, Sendable {
    case localUpdate
    case localSynchronization
    case remoteUpdate
    case conflict
    case conflictResolution
    case preDelete
    case manualRestore
    case userRestore
}

nonisolated struct StoredFileVersion: Codable, Identifiable, Equatable, Sendable {
    let versionID: UUID
    let sharedFolderID: UUID
    let relativePath: String
    let contentStorageRelativePath: String
    let size: Int64
    let contentHash: String
    let originatingPeerID: UUID
    let storedAt: Date
    let reason: VersionHistoryReason

    var id: UUID { versionID }
}

nonisolated struct TrashRecord: Codable, Identifiable, Equatable, Sendable {
    let tombstoneID: UUID
    let originalSharedFolderID: UUID
    let originalRelativePath: String
    let storedRelativePath: String
    let itemType: SyncManifestEntry.ItemType
    let size: Int64
    let deletedAt: Date
    let deletingPeerID: UUID
    let expirationDate: Date
    let integrityHash: String?

    var id: UUID { tombstoneID }
}

typealias TrashedItemRecord = TrashRecord

nonisolated struct MappingCheckpoint: Codable, Equatable, Sendable {
    let mappingID: UUID
    var highestContiguousSequence: UInt64
    var acknowledgedOperationIDs: Set<UUID>
    var acknowledgedSequencesOutsideContiguousRange: Set<UInt64>
    var latestManifestGeneration: UInt64
    var latestTombstoneGeneration: UInt64
    var updatedAt: Date
}

typealias SyncCheckpoint = MappingCheckpoint

nonisolated struct ResumableTransferState: Codable, Identifiable, Equatable, Sendable {
    let transferID: UUID
    let mappingID: UUID
    let operationID: UUID
    let totalSize: Int64
    let chunkSize: Int
    var nextExpectedOffset: Int64
    var nextChunkIndex: Int
    let stagingRelativePath: String
    let expectedFinalHash: String
    let sourceModificationDate: Date
    let expirationDate: Date
    let resumeToken: String

    var id: UUID { transferID }
}

nonisolated struct RetentionPolicy: Codable, Equatable, Sendable {
    var trashRetentionDays: Int = 30
    var versionRetentionDays: Int = 30
    var maximumVersionsPerFile: Int = 20
    var maximumRecoveryBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    var minimumFreeDiskBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
}

nonisolated enum ReconciliationState: String, Codable, Sendable {
    case idle
    case exchangingState
    case comparing
    case transferring
    case resolvingConflicts
    case verifying
    case completed
    case paused
    case failed
}

nonisolated struct ReconciliationProgress: Codable, Equatable, Sendable {
    var state: ReconciliationState = .idle
    var completedItems: Int = 0
    var totalItems: Int = 0
    var message: String?

    var fractionCompleted: Double {
        totalItems == 0 ? 0 : min(Double(completedItems) / Double(totalItems), 1)
    }
}

nonisolated enum SyncHealthState: String, Codable, Sendable {
    case upToDate
    case syncing
    case offlineChangesPending
    case reconciling
    case conflictsNeedAttention
    case paused
    case storageWarning
    case error
}

nonisolated struct SyncHealth: Codable, Equatable, Sendable {
    var state: SyncHealthState = .upToDate
    var pendingOperationCount: Int = 0
    var pendingUploadBytes: Int64 = 0
    var pendingDownloadBytes: Int64 = 0
    var unresolvedConflictCount: Int = 0
    var trashSize: Int64 = 0
    var versionHistorySize: Int64 = 0
    var lastSuccessfulSync: Date?
    var lastPeerContact: Date?
    var reconciliationProgress: ReconciliationProgress?
    var latestError: String?
}

nonisolated struct RecoveryDiagnostic: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let category: String
    let message: String
    let createdAt: Date
}
