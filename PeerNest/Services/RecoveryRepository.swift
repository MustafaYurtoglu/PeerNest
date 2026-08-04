//
//  RecoveryRepository.swift
//  PeerNest
//

import Foundation

/// Journal and checkpoint persistence intentionally share one atomic document;
/// these names describe the focused APIs without introducing parallel stores.
typealias OperationJournalStore = RecoveryRepository
typealias CheckpointStore = RecoveryRepository

actor LogicalClock {
    private let repository: RecoveryRepository

    init(repository: RecoveryRepository) {
        self.repository = repository
    }

    func current() async -> UInt64 {
        await repository.currentLogicalClock()
    }

    func tick() async throws -> UInt64 {
        try await repository.nextLogicalClock()
    }

    func merge(remoteValue: UInt64) async throws -> UInt64 {
        try await repository.nextLogicalClock(afterRemote: remoteValue)
    }
}

nonisolated struct RecoveryRepositoryDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var logicalClock: UInt64 = 0
    var journal: [JournaledSyncOperation] = []
    var conflicts: [ConflictRecord] = []
    var tombstones: [Tombstone] = []
    var trash: [TrashRecord] = []
    var versions: [StoredFileVersion] = []
    var currentVersionsByMappingAndPath: [String: FileVersion] = [:]
    var checkpoints: [String: MappingCheckpoint] = [:]
    var resumableTransfers: [ResumableTransferState] = []
    var retentionPolicy = RetentionPolicy()
    var diagnostics: [RecoveryDiagnostic] = []
}

actor RecoveryRepository {
    enum RepositoryError: LocalizedError, Equatable {
        case duplicateOperationID(UUID)
        case operationNotFound(UUID)
        case invalidTransition(JournalOperationState, JournalOperationState)
        case unsupportedSchema(Int)
        case unsafeStoredPath

        var errorDescription: String? {
            switch self {
            case let .duplicateOperationID(id): "Operation \(id.uuidString) is already journaled."
            case let .operationNotFound(id): "Operation \(id.uuidString) is not in the journal."
            case let .invalidTransition(from, to): "Journal state cannot move from \(from.rawValue) to \(to.rawValue)."
            case let .unsupportedSchema(version): "Recovery schema \(version) is not supported."
            case .unsafeStoredPath: "Recovery metadata contains an unsafe stored path."
            }
        }
    }

    let rootURL: URL
    let metadataURL: URL
    let stagingURL: URL
    let trashURL: URL
    let versionBlobsURL: URL

    private let fileManager: FileManager
    private var document: RecoveryRepositoryDocument
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL = RecoveryRepository.defaultRootURL(), fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        metadataURL = rootURL.appendingPathComponent("recovery-v1.json", isDirectory: false)
        stagingURL = rootURL.appendingPathComponent("Staging", isDirectory: true)
        trashURL = rootURL.appendingPathComponent("Trash", isDirectory: true)
        versionBlobsURL = rootURL.appendingPathComponent("Versions/Blobs", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: versionBlobsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let decoded = try decoder.decode(RecoveryRepositoryDocument.self, from: Data(contentsOf: metadataURL))
                guard decoded.schemaVersion <= RecoveryRepositoryDocument.currentSchemaVersion else {
                    throw RepositoryError.unsupportedSchema(decoded.schemaVersion)
                }
                document = decoded
            } catch {
                let quarantine = rootURL.appendingPathComponent(
                    "recovery-v1.corrupt-\(UUID().uuidString).json",
                    isDirectory: false
                )
                try? fileManager.moveItem(at: metadataURL, to: quarantine)
                document = RecoveryRepositoryDocument()
                document.diagnostics.append(RecoveryDiagnostic(
                    id: UUID(),
                    category: "metadata-corruption",
                    message: "Recovery metadata was quarantined as \(quarantine.lastPathComponent).",
                    createdAt: Date()
                ))
                try Self.write(document, to: metadataURL, encoder: encoder, fileManager: fileManager)
            }
        } else {
            document = RecoveryRepositoryDocument()
            try Self.write(document, to: metadataURL, encoder: encoder, fileManager: fileManager)
        }
    }

    nonisolated static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("PeerNest/Recovery", isDirectory: true)
    }

    nonisolated static func openDefault(fileManager: FileManager = .default) throws -> RecoveryRepository {
        let root = defaultRootURL(fileManager: fileManager)
        try RecoveryPersistenceMigrator.prepare(rootURL: root, fileManager: fileManager)
        return try RecoveryRepository(rootURL: root, fileManager: fileManager)
    }

    func snapshot() -> RecoveryRepositoryDocument { document }

    func enqueue(_ operation: JournaledSyncOperation) throws {
        guard !document.journal.contains(where: { $0.operationID == operation.operationID }) else {
            throw RepositoryError.duplicateOperationID(operation.operationID)
        }
        document.journal.append(operation)
        try persist()
    }

    func replacePendingOperations(mappingID: UUID, with operations: [JournaledSyncOperation]) throws {
        document.journal.removeAll { $0.mappingID == mappingID && !$0.state.isTerminal }
        let existingIDs = Set(document.journal.map(\.operationID))
        guard operations.allSatisfy({ !existingIDs.contains($0.operationID) }) else {
            throw RepositoryError.duplicateOperationID(operations.first(where: { existingIDs.contains($0.operationID) })!.operationID)
        }
        document.journal.append(contentsOf: operations)
        try persist()
    }

    func transition(
        operationID: UUID,
        to newState: JournalOperationState,
        errorCategory: JournalErrorCategory? = nil,
        incrementRetry: Bool = false,
        at date: Date = Date()
    ) throws {
        guard let index = document.journal.firstIndex(where: { $0.operationID == operationID }) else {
            throw RepositoryError.operationNotFound(operationID)
        }
        let oldState = document.journal[index].state
        guard Self.mayTransition(from: oldState, to: newState) else {
            throw RepositoryError.invalidTransition(oldState, newState)
        }
        document.journal[index].state = newState
        document.journal[index].updatedAt = date
        document.journal[index].lastErrorCategory = errorCategory
        if incrementRetry { document.journal[index].retryCount += 1 }
        try persist()
    }

    func pendingOperations(mappingID: UUID? = nil) -> [JournaledSyncOperation] {
        document.journal.filter {
            !$0.state.isTerminal && (mappingID == nil || $0.mappingID == mappingID)
        }
    }

    func operation(id: UUID) -> JournaledSyncOperation? {
        document.journal.first { $0.operationID == id }
    }

    @discardableResult
    func compactCompleted(olderThan cutoff: Date) throws -> Int {
        let before = document.journal.count
        document.journal.removeAll {
            ($0.state == .completed || $0.state == .cancelled) && $0.updatedAt < cutoff
        }
        let count = before - document.journal.count
        if count > 0 { try persist() }
        return count
    }

    func nextLogicalClock(afterRemote remoteValue: UInt64? = nil) throws -> UInt64 {
        document.logicalClock = max(document.logicalClock, remoteValue ?? 0) + 1
        try persist()
        return document.logicalClock
    }

    func currentLogicalClock() -> UInt64 { document.logicalClock }

    func saveCurrentVersion(_ version: FileVersion, mappingID: UUID) throws {
        document.currentVersionsByMappingAndPath[Self.versionKey(mappingID: mappingID, path: version.relativePath)] = version
        try persist()
    }

    func currentVersion(mappingID: UUID, relativePath: String) -> FileVersion? {
        document.currentVersionsByMappingAndPath[Self.versionKey(mappingID: mappingID, path: relativePath)]
    }

    func addConflict(_ conflict: ConflictRecord) throws {
        guard !document.conflicts.contains(where: { $0.conflictID == conflict.conflictID }) else { return }
        document.conflicts.append(conflict)
        try persist()
    }

    func conflicts(unresolvedOnly: Bool = false) -> [ConflictRecord] {
        document.conflicts.filter { !unresolvedOnly || $0.resolutionState == .unresolved }
    }

    func resolveConflict(id: UUID, resolution: ConflictResolutionState, copyPaths: [String] = []) throws {
        guard let index = document.conflicts.firstIndex(where: { $0.conflictID == id }) else { return }
        guard document.conflicts[index].resolutionState == .unresolved || resolution == .dismissed else { return }
        document.conflicts[index].resolutionState = resolution
        document.conflicts[index].userDecision = resolution
        document.conflicts[index].generatedConflictCopyPaths = copyPaths
        try persist()
    }

    func addTombstone(_ tombstone: Tombstone) throws {
        if let index = document.tombstones.firstIndex(where: { $0.tombstoneID == tombstone.tombstoneID }) {
            document.tombstones[index].acknowledgedPeerIDs.formUnion(tombstone.acknowledgedPeerIDs)
        } else {
            document.tombstones.append(tombstone)
        }
        try persist()
    }

    func tombstones(mappingID: UUID? = nil) -> [Tombstone] {
        document.tombstones.filter { mappingID == nil || $0.mappingID == mappingID }
    }

    func acknowledgeTombstone(id: UUID, peerID: UUID) throws {
        guard let index = document.tombstones.firstIndex(where: { $0.tombstoneID == id }) else { return }
        document.tombstones[index].acknowledgedPeerIDs.insert(peerID)
        try persist()
    }

    func addTrashRecord(_ record: TrashRecord) throws {
        document.trash.removeAll { $0.tombstoneID == record.tombstoneID }
        document.trash.append(record)
        try persist()
    }

    func trashRecords() -> [TrashRecord] { document.trash }

    func removeTrashRecord(id: UUID) throws {
        document.trash.removeAll { $0.tombstoneID == id }
        if let index = document.tombstones.firstIndex(where: { $0.tombstoneID == id }) {
            document.tombstones[index].restoreState = .purged
        }
        try persist()
    }

    func markTrashRestored(id: UUID) throws {
        document.trash.removeAll { $0.tombstoneID == id }
        if let index = document.tombstones.firstIndex(where: { $0.tombstoneID == id }) {
            document.tombstones[index].restoreState = .restored
        }
        try persist()
    }

    func addStoredVersion(_ version: StoredFileVersion) throws {
        guard !document.versions.contains(where: { $0.versionID == version.versionID }) else { return }
        document.versions.append(version)
        try persist()
    }

    func storedVersions(sharedFolderID: UUID? = nil, relativePath: String? = nil) -> [StoredFileVersion] {
        document.versions.filter {
            (sharedFolderID == nil || $0.sharedFolderID == sharedFolderID)
                && (relativePath == nil || $0.relativePath == relativePath)
        }.sorted { $0.storedAt > $1.storedAt }
    }

    func removeStoredVersions(ids: Set<UUID>) throws {
        document.versions.removeAll { ids.contains($0.versionID) }
        try persist()
    }

    func checkpoint(mappingID: UUID) -> MappingCheckpoint {
        document.checkpoints[mappingID.uuidString] ?? MappingCheckpoint(
            mappingID: mappingID,
            highestContiguousSequence: 0,
            acknowledgedOperationIDs: [],
            acknowledgedSequencesOutsideContiguousRange: [],
            latestManifestGeneration: 0,
            latestTombstoneGeneration: 0,
            updatedAt: Date()
        )
    }

    func acknowledge(operationID: UUID, logicalSequence: UInt64, mappingID: UUID, at date: Date = Date()) throws {
        var checkpoint = self.checkpoint(mappingID: mappingID)
        checkpoint.acknowledgedOperationIDs.insert(operationID)
        if logicalSequence == checkpoint.highestContiguousSequence + 1 {
            checkpoint.highestContiguousSequence = logicalSequence
            while checkpoint.acknowledgedSequencesOutsideContiguousRange.remove(checkpoint.highestContiguousSequence + 1) != nil {
                checkpoint.highestContiguousSequence += 1
            }
        } else if logicalSequence > checkpoint.highestContiguousSequence + 1 {
            checkpoint.acknowledgedSequencesOutsideContiguousRange.insert(logicalSequence)
        }
        checkpoint.updatedAt = date
        document.checkpoints[mappingID.uuidString] = checkpoint
        try persist()
    }

    func saveTransfer(_ transfer: ResumableTransferState) throws {
        document.resumableTransfers.removeAll { $0.transferID == transfer.transferID }
        document.resumableTransfers.append(transfer)
        try persist()
    }

    func transfer(id: UUID) -> ResumableTransferState? {
        document.resumableTransfers.first { $0.transferID == id }
    }

    func removeTransfer(id: UUID) throws {
        document.resumableTransfers.removeAll { $0.transferID == id }
        try persist()
    }

    func transfers() -> [ResumableTransferState] { document.resumableTransfers }

    func retentionPolicy() -> RetentionPolicy { document.retentionPolicy }

    func setRetentionPolicy(_ policy: RetentionPolicy) throws {
        document.retentionPolicy = policy
        try persist()
    }

    func addDiagnostic(category: String, message: String) throws -> UUID {
        let item = RecoveryDiagnostic(id: UUID(), category: category, message: message, createdAt: Date())
        document.diagnostics.append(item)
        if document.diagnostics.count > 500 { document.diagnostics.removeFirst(document.diagnostics.count - 500) }
        try persist()
        return item.id
    }

    func diagnostics() -> [RecoveryDiagnostic] { document.diagnostics }

    func flush() throws { try persist() }

    func storedURL(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw RepositoryError.unsafeStoredPath
        }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") else {
            throw RepositoryError.unsafeStoredPath
        }
        return candidate
    }

    private func persist() throws {
        try Self.write(document, to: metadataURL, encoder: encoder, fileManager: fileManager)
    }

    private nonisolated static func write(
        _ document: RecoveryRepositoryDocument,
        to url: URL,
        encoder: JSONEncoder,
        fileManager: FileManager
    ) throws {
        let data = try encoder.encode(document)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private nonisolated static func versionKey(mappingID: UUID, path: String) -> String {
        "\(mappingID.uuidString.lowercased())|\(path)"
    }

    private nonisolated static func mayTransition(
        from: JournalOperationState,
        to: JournalOperationState
    ) -> Bool {
        if from == to { return true }
        if from == .permanentlyFailed && to == .retryScheduled { return true }
        if from.isTerminal { return false }
        return switch (from, to) {
        case (.queued, .preparing), (.queued, .waitingForPeer), (.queued, .cancelled),
             (.preparing, .waitingForPeer), (.preparing, .sending), (.preparing, .retryScheduled),
             (.waitingForPeer, .preparing), (.waitingForPeer, .sending), (.waitingForPeer, .cancelled),
             (.sending, .awaitingAcknowledgment), (.sending, .retryScheduled),
             (.awaitingAcknowledgment, .completed), (.awaitingAcknowledgment, .retryScheduled),
             (.retryScheduled, .preparing), (.retryScheduled, .waitingForPeer), (.retryScheduled, .sending),
             (_, .conflicted), (_, .permanentlyFailed): true
        default: false
        }
    }
}
