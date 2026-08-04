//
//  RecoveryServices.swift
//  PeerNest
//

import Foundation
import UserNotifications

nonisolated enum RecoveryCapacityGuard {
    static func canAccept(
        additionalBytes: Int64,
        repository: RecoveryRepository,
        fileManager: FileManager
    ) async -> Bool {
        guard additionalBytes > 0 else { return true }
        let policy = await repository.retentionPolicy()
        let currentUsage = recursiveFileSize(at: repository.rootURL, fileManager: fileManager)
        guard currentUsage <= policy.maximumRecoveryBytes - additionalBytes else { return false }
        if let available = try? repository.rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return available >= policy.minimumFreeDiskBytes + additionalBytes
        }
        return true
    }

    private static func recursiveFileSize(at root: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

actor PeerNestTrashManager {
    enum TrashError: LocalizedError, Equatable {
        case sourceMissing
        case permanentDeletionRequiresConfirmation
        case integrityVerificationFailed
        case insufficientRecoveryCapacity

        var errorDescription: String? {
            switch self {
            case .sourceMissing: "The item to delete is no longer available."
            case .permanentDeletionRequiresConfirmation: "Permanent deletion requires confirmation."
            case .integrityVerificationFailed: "The recovery copy could not be verified."
            case .insufficientRecoveryCapacity: "PeerNest recovery storage does not have enough safe capacity."
            }
        }
    }

    private let repository: RecoveryRepository
    private let fileManager: FileManager

    init(repository: RecoveryRepository, fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    @discardableResult
    func moveToTrash(
        sharedFolderID: UUID,
        mappingID: UUID,
        rootURL: URL,
        relativePath: String,
        deletingPeerID: UUID,
        logicalClock: UInt64,
        deletedVersionID: UUID? = nil,
        now: Date = Date()
    ) async throws -> TrashRecord {
        let source = try SharedPathValidator.destinationURL(in: rootURL, relativePath: relativePath)
        guard fileManager.fileExists(atPath: source.path) else { throw TrashError.sourceMissing }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        let type: SyncManifestEntry.ItemType = values.isDirectory == true ? .directory : .file
        let hash = values.isRegularFile == true ? try await FileHashing.sha256(of: source) : nil
        let size = values.isDirectory == true ? recursiveSize(source) : Int64(values.fileSize ?? 0)
        guard await RecoveryCapacityGuard.canAccept(
            additionalBytes: size,
            repository: repository,
            fileManager: fileManager
        ) else { throw TrashError.insufficientRecoveryCapacity }
        let policy = await repository.retentionPolicy()
        let tombstoneID = UUID()
        let storedRelativePath = "Trash/\(tombstoneID.uuidString)/\(source.lastPathComponent)"
        let destination = try await repository.storedURL(for: storedRelativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
            if let hash, try await FileHashing.sha256(of: destination) != hash {
                try? fileManager.removeItem(at: destination)
                throw TrashError.integrityVerificationFailed
            }
            if type == .directory, recursiveSize(destination) != size {
                try? fileManager.removeItem(at: destination)
                throw TrashError.integrityVerificationFailed
            }
            try fileManager.removeItem(at: source)
        }

        let expiration = Calendar.current.date(byAdding: .day, value: policy.trashRetentionDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(policy.trashRetentionDays * 86_400))
        let record = TrashRecord(
            tombstoneID: tombstoneID,
            originalSharedFolderID: sharedFolderID,
            originalRelativePath: relativePath,
            storedRelativePath: storedRelativePath,
            itemType: type,
            size: size,
            deletedAt: now,
            deletingPeerID: deletingPeerID,
            expirationDate: expiration,
            integrityHash: hash
        )
        let tombstone = Tombstone(
            tombstoneID: tombstoneID,
            sharedFolderID: sharedFolderID,
            mappingID: mappingID,
            relativePath: relativePath,
            deletedVersionID: deletedVersionID,
            deletingPeerID: deletingPeerID,
            deletedAt: now,
            logicalClock: logicalClock,
            expirationDate: expiration,
            restoreState: .active,
            acknowledgedPeerIDs: [deletingPeerID]
        )
        try await repository.addTombstone(tombstone)
        try await repository.addTrashRecord(record)
        return record
    }

    @discardableResult
    func restore(_ record: TrashRecord, to rootURL: URL) async throws -> URL {
        let stored = try await repository.storedURL(for: record.storedRelativePath)
        guard fileManager.fileExists(atPath: stored.path) else { throw TrashError.sourceMissing }
        var destination = try SharedPathValidator.destinationURL(in: rootURL, relativePath: record.originalRelativePath)
        if fileManager.fileExists(atPath: destination.path) {
            destination = uniqueRestoredURL(for: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: stored, to: destination)
        try? fileManager.removeItem(at: stored.deletingLastPathComponent())
        try await repository.markTrashRestored(id: record.tombstoneID)
        return destination
    }

    func permanentlyDelete(_ record: TrashRecord, confirmed: Bool) async throws {
        guard confirmed else { throw TrashError.permanentDeletionRequiresConfirmation }
        let stored = try await repository.storedURL(for: record.storedRelativePath)
        if fileManager.fileExists(atPath: stored.path) { try fileManager.removeItem(at: stored) }
        try? fileManager.removeItem(at: stored.deletingLastPathComponent())
        try await repository.removeTrashRecord(id: record.tombstoneID)
    }

    func usage() async -> Int64 { await repository.trashRecords().reduce(0) { $0 + $1.size } }

    private func uniqueRestoredURL(for original: URL) -> URL {
        let folder = original.deletingLastPathComponent()
        let filename = original.lastPathComponent as NSString
        let ext = filename.pathExtension
        let base = ext.isEmpty ? filename as String : filename.deletingPathExtension
        for index in 1...10_000 {
            let discriminator = index == 1 ? "" : " \(index)"
            let name = "\(base) (Restored\(discriminator))\(ext.isEmpty ? "" : ".\(ext)")"
            let candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
    }

    private func recursiveSize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

actor VersionHistoryStore {
    enum HistoryError: LocalizedError {
        case sourceMissing
        case storedContentMissing
        case hashMismatch
        case insufficientRecoveryCapacity

        var errorDescription: String? {
            switch self {
            case .sourceMissing: "The file to archive is missing."
            case .storedContentMissing: "The stored version content is missing."
            case .hashMismatch: "The stored version failed integrity verification."
            case .insufficientRecoveryCapacity: "PeerNest recovery storage does not have enough safe capacity."
            }
        }
    }

    private let repository: RecoveryRepository
    private let fileManager: FileManager

    init(repository: RecoveryRepository, fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    @discardableResult
    func store(
        fileURL: URL,
        sharedFolderID: UUID,
        relativePath: String,
        originatingPeerID: UUID,
        reason: VersionHistoryReason,
        now: Date = Date()
    ) async throws -> StoredFileVersion {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw HistoryError.sourceMissing }
        let hash = try await FileHashing.sha256(of: fileURL)
        let relativeBlobPath = "Versions/Blobs/\(hash.prefix(2))/\(hash)"
        let blobURL = try await repository.storedURL(for: relativeBlobPath)
        try fileManager.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: blobURL.path) {
            guard await RecoveryCapacityGuard.canAccept(
                additionalBytes: Int64(values.fileSize ?? 0),
                repository: repository,
                fileManager: fileManager
            ) else { throw HistoryError.insufficientRecoveryCapacity }
            let temporary = blobURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
            try fileManager.copyItem(at: fileURL, to: temporary)
            guard try await FileHashing.sha256(of: temporary) == hash else {
                try? fileManager.removeItem(at: temporary)
                throw HistoryError.hashMismatch
            }
            try fileManager.moveItem(at: temporary, to: blobURL)
        }
        let stored = StoredFileVersion(
            versionID: UUID(),
            sharedFolderID: sharedFolderID,
            relativePath: relativePath,
            contentStorageRelativePath: relativeBlobPath,
            size: Int64(values.fileSize ?? 0),
            contentHash: hash,
            originatingPeerID: originatingPeerID,
            storedAt: now,
            reason: reason
        )
        try await repository.addStoredVersion(stored)
        return stored
    }

    @discardableResult
    func restore(_ version: StoredFileVersion, to destination: URL) async throws -> URL {
        let blobURL = try await repository.storedURL(for: version.contentStorageRelativePath)
        guard fileManager.fileExists(atPath: blobURL.path) else { throw HistoryError.storedContentMissing }
        guard try await FileHashing.sha256(of: blobURL) == version.contentHash else { throw HistoryError.hashMismatch }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".peernest-restore-\(UUID().uuidString)")
        try fileManager.copyItem(at: blobURL, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    func usage() async -> Int64 {
        let versions = await repository.storedVersions()
        var sizesByHash: [String: Int64] = [:]
        for version in versions { sizesByHash[version.contentHash] = version.size }
        return sizesByHash.values.reduce(0, +)
    }
}

nonisolated struct RecoveryCleanupSummary: Equatable, Sendable {
    let eligibleTrashItems: Int
    let eligibleVersions: Int
    let reclaimableBytes: Int64
}

actor RecoveryStorageManager {
    private let repository: RecoveryRepository
    private let fileManager: FileManager

    init(repository: RecoveryRepository, fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    func cleanupSummary(now: Date = Date()) async -> RecoveryCleanupSummary {
        let document = await repository.snapshot()
        let plan = cleanupPlan(document: document, now: now)
        let remainingHashes = Set(document.versions.filter { !plan.versionIDs.contains($0.versionID) }.map(\.contentHash))
        let reclaimableVersionBytes = Dictionary(grouping: document.versions.filter {
            plan.versionIDs.contains($0.versionID) && !remainingHashes.contains($0.contentHash)
        }, by: \.contentHash).values.reduce(Int64(0)) { total, matches in
            total + (matches.first?.size ?? 0)
        }
        return RecoveryCleanupSummary(
            eligibleTrashItems: plan.trash.count,
            eligibleVersions: plan.versionIDs.count,
            reclaimableBytes: plan.trash.reduce(0) { $0 + $1.size } + reclaimableVersionBytes
        )
    }

    func cleanup(now: Date = Date()) async throws -> RecoveryCleanupSummary {
        let summary = await cleanupSummary(now: now)
        let document = await repository.snapshot()
        let plan = cleanupPlan(document: document, now: now)
        for record in plan.trash {
            let url = try await repository.storedURL(for: record.storedRelativePath)
            try? fileManager.removeItem(at: url)
            try await repository.removeTrashRecord(id: record.tombstoneID)
        }
        let removed = document.versions.filter { plan.versionIDs.contains($0.versionID) }
        try await repository.removeStoredVersions(ids: plan.versionIDs)
        let remainingHashes = Set(await repository.storedVersions().map(\.contentHash))
        for version in removed where !remainingHashes.contains(version.contentHash) {
            let url = try await repository.storedURL(for: version.contentStorageRelativePath)
            try? fileManager.removeItem(at: url)
        }
        for transfer in document.resumableTransfers where transfer.expirationDate < now {
            let url = try await repository.storedURL(for: transfer.stagingRelativePath)
            try? fileManager.removeItem(at: url)
            try await repository.removeTransfer(id: transfer.transferID)
        }
        return summary
    }

    private func cleanupPlan(
        document: RecoveryRepositoryDocument,
        now: Date
    ) -> (trash: [TrashRecord], versionIDs: Set<UUID>) {
        let activeConflicts = document.conflicts.filter { $0.resolutionState == .unresolved }
        let protectedVersionIDs = Set(activeConflicts.flatMap {
            [$0.localVersion?.versionID, $0.remoteVersion?.versionID, $0.baseVersion?.versionID].compactMap { $0 }
        })
        let protectedHashes = Set(activeConflicts.flatMap {
            [$0.localVersion?.contentHash, $0.remoteVersion?.contentHash, $0.baseVersion?.contentHash].compactMap { $0 }
        })
        let protectedPaths = Set(document.journal.filter { !$0.state.isTerminal }.compactMap {
            $0.contentMetadata?.stagingRelativePath
        })
        let eligibleTrash = document.trash.filter { record in
            record.expirationDate < now && document.tombstones.first(where: { $0.tombstoneID == record.tombstoneID })
                .map { $0.acknowledgedPeerIDs.count >= 2 } == true
        }
        let cutoff = now.addingTimeInterval(TimeInterval(-document.retentionPolicy.versionRetentionDays * 86_400))
        func isProtected(_ version: StoredFileVersion) -> Bool {
            protectedVersionIDs.contains(version.versionID)
                || protectedHashes.contains(version.contentHash)
                || protectedPaths.contains(version.contentStorageRelativePath)
        }
        var eligibleIDs = Set(document.versions.filter {
            $0.storedAt < cutoff && !isProtected($0)
        }.map(\.versionID))
        let grouped = Dictionary(grouping: document.versions, by: { "\($0.sharedFolderID)|\($0.relativePath)" })
        for versions in grouped.values {
            for extra in versions.sorted(by: { $0.storedAt > $1.storedAt }).dropFirst(document.retentionPolicy.maximumVersionsPerFile) {
                if !isProtected(extra) { eligibleIDs.insert(extra.versionID) }
            }
        }

        func projectedUsage(removing ids: Set<UUID>) -> Int64 {
            let versions = document.versions.filter { !ids.contains($0.versionID) }
            let versionBytes = Dictionary(grouping: versions, by: \.contentHash).values.reduce(Int64(0)) {
                $0 + ($1.first?.size ?? 0)
            }
            return versionBytes + document.trash.reduce(0) { $0 + $1.size }
                + document.resumableTransfers.reduce(0) { $0 + $1.totalSize }
        }
        if projectedUsage(removing: eligibleIDs) > document.retentionPolicy.maximumRecoveryBytes {
            for version in document.versions.sorted(by: { $0.storedAt < $1.storedAt })
            where !eligibleIDs.contains(version.versionID) && !isProtected(version) {
                eligibleIDs.insert(version.versionID)
                if projectedUsage(removing: eligibleIDs) <= document.retentionPolicy.maximumRecoveryBytes { break }
            }
        }
        return (eligibleTrash, eligibleIDs)
    }

    func hasCriticalDiskPressure() async -> Bool {
        let policy = await repository.retentionPolicy()
        let values = try? repository.rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? Int64.max) < policy.minimumFreeDiskBytes
    }
}

@MainActor
final class RecoveryNotificationService {
    struct Preferences: Codable, Equatable {
        var conflicts = true
        var reconciliation = true
        var storageWarnings = true
        var permanentFailures = true
    }

    private(set) var preferences = Preferences()

    func enableNotificationsExplicitly() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(identifier: String, title: String, body: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }
}
