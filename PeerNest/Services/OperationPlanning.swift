//
//  OperationPlanning.swift
//  PeerNest
//

import Foundation

nonisolated enum OperationCoalescer {
    static func coalesce(_ operations: [JournaledSyncOperation]) -> [JournaledSyncOperation] {
        let grouped = Dictionary(grouping: operations) { "\($0.mappingID)|\($0.sharedFolderID)" }
        return grouped.values.flatMap(coalesceSingleMapping).sorted { $0.createdAt < $1.createdAt }
    }

    private static func coalesceSingleMapping(_ input: [JournaledSyncOperation]) -> [JournaledSyncOperation] {
        var result: [JournaledSyncOperation] = []
        for operation in input.sorted(by: { $0.createdAt < $1.createdAt }) {
            if operation.operationType == .rename || operation.operationType == .move,
               let destination = operation.relativeDestinationPath,
               let index = result.lastIndex(where: {
                   ($0.operationType == .rename || $0.operationType == .move)
                       && $0.relativeDestinationPath == operation.relativeSourcePath
               }) {
                result[index] = replacing(
                    result[index],
                    type: result[index].operationType,
                    destination: destination,
                    contentFrom: operation
                )
                continue
            }

            guard let index = result.lastIndex(where: {
                $0.relativeSourcePath == operation.relativeSourcePath
                    && $0.mappingID == operation.mappingID
                    && !$0.state.isTerminal
            }) else {
                result.append(operation)
                continue
            }

            let prior = result[index]
            switch (prior.operationType, operation.operationType) {
            case (.createFile, .updateFile):
                result[index] = replacing(prior, type: .createFile, destination: nil, contentFrom: operation)
            case (.updateFile, .updateFile):
                result[index] = operation
            case (.createFile, .delete), (.createDirectory, .delete):
                result.remove(at: index)
            case (.updateFile, .delete):
                result[index] = operation
            case (.createDirectory, .createDirectory):
                break
            default:
                result.append(operation)
            }
        }
        return result
    }

    private static func replacing(
        _ original: JournaledSyncOperation,
        type: SyncOperation.OperationType,
        destination: String?,
        contentFrom latest: JournaledSyncOperation
    ) -> JournaledSyncOperation {
        let operation = try! SyncOperation(
            id: original.operationID,
            sharedFolderID: original.sharedFolderID,
            type: type,
            relativePath: original.relativeSourcePath,
            destinationRelativePath: destination
        )
        return JournaledSyncOperation(
            operation: operation,
            mappingID: original.mappingID,
            originPeerID: original.originPeerID,
            destinationPeerID: original.destinationPeerID,
            expectedSourceVersion: latest.expectedSourceVersion ?? original.expectedSourceVersion,
            expectedDestinationVersion: latest.expectedDestinationVersion ?? original.expectedDestinationVersion,
            contentMetadata: latest.contentMetadata ?? original.contentMetadata,
            createdAt: original.createdAt,
            state: .queued,
            dependencyOperationIDs: Array(Set(original.dependencyOperationIDs + latest.dependencyOperationIDs)),
            logicalSequence: latest.logicalSequence
        )
    }
}

nonisolated enum OperationDependencyResolver {
    static func ordered(_ operations: [JournaledSyncOperation]) -> [JournaledSyncOperation] {
        guard operations.count > 1 else { return operations }
        let ids = Set(operations.map(\.operationID))
        var dependencies = Dictionary(uniqueKeysWithValues: operations.map {
            ($0.operationID, Set($0.dependencyOperationIDs.filter(ids.contains)))
        })

        for operation in operations {
            for candidate in operations where candidate.operationID != operation.operationID {
                if candidate.operationType == .createDirectory,
                   isParent(candidate.relativeSourcePath, of: operation.relativeSourcePath) {
                    dependencies[operation.operationID, default: []].insert(candidate.operationID)
                }
                if operation.operationType == .delete, candidate.operationType == .delete,
                   isParent(operation.relativeSourcePath, of: candidate.relativeSourcePath) {
                    dependencies[operation.operationID, default: []].insert(candidate.operationID)
                }
                if operation.operationType == .rename || operation.operationType == .move,
                   candidate.relativeSourcePath == operation.relativeSourcePath,
                   candidate.operationType == .createFile || candidate.operationType == .createDirectory {
                    dependencies[operation.operationID, default: []].insert(candidate.operationID)
                }
            }
        }

        var remaining = Dictionary(uniqueKeysWithValues: operations.map { ($0.operationID, $0) })
        var result: [JournaledSyncOperation] = []
        while !remaining.isEmpty {
            let ready = remaining.values.filter { operation in
                dependencies[operation.operationID, default: []].isDisjoint(with: Set(remaining.keys))
            }.sorted(by: preferredOrder)
            guard !ready.isEmpty else {
                return result + remaining.values.sorted(by: preferredOrder)
            }
            for operation in ready {
                result.append(operation)
                remaining[operation.operationID] = nil
            }
        }
        return result
    }

    private static func isParent(_ possibleParent: String, of child: String) -> Bool {
        child.hasPrefix(possibleParent + "/")
    }

    private static func preferredOrder(_ lhs: JournaledSyncOperation, _ rhs: JournaledSyncOperation) -> Bool {
        let leftRank = rank(lhs)
        let rightRank = rank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.operationType == .delete {
            let leftDepth = lhs.relativeSourcePath.split(separator: "/").count
            let rightDepth = rhs.relativeSourcePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func rank(_ operation: JournaledSyncOperation) -> Int {
        switch operation.operationType {
        case .createDirectory: 0
        case .createFile, .updateFile: 1
        case .rename, .move: 2
        case .delete: 3
        }
    }
}

nonisolated enum FileVersionComparator {
    static func compare(local: FileVersion, remote: FileVersion) -> FileVersionRelationship {
        if local.versionID == remote.versionID
            || (local.contentHash != nil && local.contentHash == remote.contentHash
                && local.itemType == remote.itemType) {
            return .identical
        }
        if local.parentVersionID == remote.versionID { return .localDescendsFromRemote }
        if remote.parentVersionID == local.versionID { return .remoteDescendsFromLocal }
        if local.originatingPeerID == remote.originatingPeerID {
            return local.logicalSequence > remote.logicalSequence
                ? .localDescendsFromRemote : .remoteDescendsFromLocal
        }
        return .concurrent
    }
}

nonisolated enum ConflictDetector {
    static func conflictType(
        local: FileVersion?,
        remote: FileVersion?,
        localOperation: SyncOperation.OperationType? = nil,
        remoteOperation: SyncOperation.OperationType
    ) -> ConflictType? {
        if localOperation == .delete || remoteOperation == .delete {
            return (localOperation == .delete && remoteOperation == .delete) ? nil : .deleteVsModify
        }
        guard let local, let remote else { return nil }
        if local.itemType != remote.itemType { return .fileVsDirectory }
        guard FileVersionComparator.compare(local: local, remote: remote) == .concurrent else { return nil }
        if local.parentVersionID == remote.parentVersionID {
            return local.parentVersionID == nil ? .createVsCreate : .concurrentModification
        }
        return .concurrentModification
    }
}

nonisolated enum ConflictCopyNamer {
    static func path(
        originalPath: String,
        losingPeerName: String,
        losingPeerID: UUID,
        versionID: UUID,
        occupiedPaths: Set<String> = []
    ) -> String {
        let path = originalPath as NSString
        let parent = path.deletingLastPathComponent
        let filename = path.lastPathComponent as NSString
        let ext = filename.pathExtension
        var base = ext.isEmpty ? filename as String : filename.deletingPathExtension
        var safePeer = losingPeerName
            .replacingOccurrences(of: "[/\\\\:]", with: "-", options: .regularExpression)
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safePeer.isEmpty { safePeer = "Peer-\(losingPeerID.uuidString.prefix(8))" }
        safePeer = String(safePeer.prefix(48))
        let token = versionID.uuidString.lowercased().prefix(8)
        let suffix = "Conflict from \(safePeer) \(token)"
        let maxBaseLength = max(1, 180 - suffix.count - ext.count)
        base = String(base.prefix(maxBaseLength))

        for index in 0..<10_000 {
            let discriminator = index == 0 ? "" : " \(index + 1)"
            let copyName = "\(base) (\(suffix)\(discriminator))\(ext.isEmpty ? "" : ".\(ext)")"
            let candidate = parent.isEmpty ? copyName : "\(parent)/\(copyName)"
            if !occupiedPaths.contains(candidate) { return candidate }
        }
        return "\(originalPath).conflict-\(versionID.uuidString)"
    }

    static func remoteKeepsOriginal(localPeerID: UUID, remotePeerID: UUID) -> Bool {
        remotePeerID.uuidString.lowercased() < localPeerID.uuidString.lowercased()
    }
}

nonisolated enum ConflictResolver {
    struct Decision: Equatable, Sendable {
        let originalVersion: FileVersion
        let conflictCopyVersion: FileVersion
    }

    /// Descendants win over ancestors. Concurrent versions use the stable peer
    /// UUID as a deterministic tie-breaker on both Macs.
    static func automaticDecision(local: FileVersion, remote: FileVersion) -> Decision {
        switch FileVersionComparator.compare(local: local, remote: remote) {
        case .remoteDescendsFromLocal:
            Decision(originalVersion: remote, conflictCopyVersion: local)
        case .localDescendsFromRemote, .identical:
            Decision(originalVersion: local, conflictCopyVersion: remote)
        case .concurrent:
            if remote.originatingPeerID.uuidString.lowercased()
                < local.originatingPeerID.uuidString.lowercased() {
                Decision(originalVersion: remote, conflictCopyVersion: local)
            } else {
                Decision(originalVersion: local, conflictCopyVersion: remote)
            }
        }
    }
}
