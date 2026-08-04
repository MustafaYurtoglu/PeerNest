//
//  SyncPlanner.swift
//  PeerNest
//

import Foundation

struct SyncPlan: Sendable {
    let operations: [SyncOperation]
    let conflicts: [String]
}

enum SyncPlanner {
    static func planConservativeInitialPush(
        source: [SyncManifestEntry],
        destination: [SyncManifestEntry],
        sourceSharedFolderID: UUID,
        sourcePeerName: String,
        now: Date = Date()
    ) throws -> SyncPlan {
        let destinationByPath = Dictionary(uniqueKeysWithValues: destination.map { ($0.relativePath, $0) })
        var reservedPaths = Set(destination.map(\.relativePath))
        var operations: [SyncOperation] = []
        var conflicts: [String] = []

        for entry in source {
            if let existing = destinationByPath[entry.relativePath] {
                guard entry.itemType == .file, existing.itemType == .file,
                      !equivalent(entry, existing) else { continue }
                let conflictPath = uniqueConflictPath(
                    for: entry.relativePath,
                    peerName: sourcePeerName,
                    date: now,
                    reservedPaths: &reservedPaths
                )
                operations.append(try SyncOperation(
                    sharedFolderID: sourceSharedFolderID,
                    type: .createFile,
                    relativePath: entry.relativePath,
                    destinationRelativePath: conflictPath
                ))
                conflicts.append(conflictPath)
            } else {
                operations.append(try SyncOperation(
                    sharedFolderID: sourceSharedFolderID,
                    type: entry.itemType == .directory ? .createDirectory : .createFile,
                    relativePath: entry.relativePath
                ))
                reservedPaths.insert(entry.relativePath)
            }
        }

        operations.sort { lhs, rhs in
            let leftDirectory = lhs.type == .createDirectory
            let rightDirectory = rhs.type == .createDirectory
            if leftDirectory != rightDirectory { return leftDirectory }
            if leftDirectory {
                return depth(lhs.relativePath) < depth(rhs.relativePath)
            }
            return lhs.relativePath < rhs.relativePath
        }
        return SyncPlan(operations: operations, conflicts: conflicts)
    }

    static func equivalent(_ lhs: SyncManifestEntry, _ rhs: SyncManifestEntry) -> Bool {
        guard lhs.itemType == rhs.itemType else { return false }
        if lhs.itemType == .directory { return true }
        if let leftHash = lhs.contentHash, let rightHash = rhs.contentHash { return leftHash == rightHash }
        return lhs.size == rhs.size
            && abs(lhs.modificationDate.timeIntervalSince(rhs.modificationDate)) < 1
    }

    private static func uniqueConflictPath(
        for relativePath: String,
        peerName: String,
        date: Date,
        reservedPaths: inout Set<String>
    ) -> String {
        let path = relativePath as NSString
        let parent = path.deletingLastPathComponent
        let filename = path.lastPathComponent as NSString
        let ext = filename.pathExtension
        let base = ext.isEmpty ? filename as String : filename.deletingPathExtension
        let cleanPeer = peerName
            .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let suffix = "Conflict from \(cleanPeer.isEmpty ? "Peer" : cleanPeer) \(formatter.string(from: date))"
        var index = 0
        while true {
            let discriminator = index == 0 ? "" : " \(index + 1)"
            let filename = "\(base) (\(suffix)\(discriminator))\(ext.isEmpty ? "" : ".\(ext)")"
            let candidate = parent.isEmpty ? filename : "\(parent)/\(filename)"
            if !reservedPaths.contains(candidate) {
                reservedPaths.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    private static func depth(_ path: String) -> Int { path.split(separator: "/").count }
}
