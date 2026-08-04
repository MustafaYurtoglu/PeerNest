//
//  AppliedOperationRegistry.swift
//  PeerNest
//

import Foundation

actor AppliedOperationRegistry {
    struct Entry: Sendable {
        let operationID: UUID
        let sharedFolderID: UUID
        let relativePath: String
        let expectedHash: String?
        let expiration: Date
    }

    private var entries: [Entry] = []
    private var processedOperationIDs: [UUID: Date] = [:]
    private let maximumEntries: Int
    private let lifetime: TimeInterval

    init(maximumEntries: Int = 1_000, lifetime: TimeInterval = 30) {
        self.maximumEntries = maximumEntries
        self.lifetime = lifetime
    }

    func register(
        operationID: UUID,
        sharedFolderID: UUID,
        relativePath: String,
        expectedHash: String?,
        now: Date = Date()
    ) {
        purgeExpired(now: now)
        entries.append(Entry(
            operationID: operationID,
            sharedFolderID: sharedFolderID,
            relativePath: relativePath,
            expectedHash: expectedHash,
            expiration: now.addingTimeInterval(lifetime)
        ))
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
    }

    func shouldSuppress(
        sharedFolderID: UUID,
        relativePath: String,
        resultingHash: String?,
        now: Date = Date()
    ) -> Bool {
        purgeExpired(now: now)
        guard let index = entries.firstIndex(where: {
            $0.sharedFolderID == sharedFolderID
                && $0.relativePath == relativePath
                && ($0.expectedHash == nil || $0.expectedHash == resultingHash)
        }) else { return false }
        entries.remove(at: index)
        return true
    }

    func claimOperation(_ operationID: UUID, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        guard processedOperationIDs[operationID] == nil else { return false }
        processedOperationIDs[operationID] = now.addingTimeInterval(max(lifetime, 300))
        if processedOperationIDs.count > maximumEntries,
           let oldest = processedOperationIDs.min(by: { $0.value < $1.value })?.key {
            processedOperationIDs[oldest] = nil
        }
        return true
    }

    func purgeExpired(now: Date = Date()) {
        entries.removeAll { $0.expiration <= now }
        processedOperationIDs = processedOperationIDs.filter { $0.value > now }
    }

    func pendingEntryCount() -> Int { entries.count }
}
