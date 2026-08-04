//
//  ManifestBuilder.swift
//  PeerNest
//

import Foundation

actor ManifestBuilder {
    struct Result: Sendable {
        let entries: [SyncManifestEntry]
        let skippedPaths: [String]
    }

    func build(rootURL: URL, includeHashes: Bool = false) async throws -> Result {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        var entries: [SyncManifestEntry] = []
        var skipped: [String] = []
        for url in try Self.enumeratedURLs(rootURL: rootURL, keys: keys) {
            try Task.checkCancellation()
            guard let relativePath = try? SharedPathValidator.safeRelativePath(from: rootURL, to: url) else {
                continue
            }
            if SharedItemIgnorePolicy.shouldIgnore(relativePath: relativePath) {
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    continue
                }
                let itemType: SyncManifestEntry.ItemType
                if values.isDirectory == true { itemType = .directory }
                else if values.isRegularFile == true { itemType = .file }
                else { continue }

                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate ?? .distantPast
                let hash = includeHashes && itemType == .file ? try await FileHashing.sha256(of: url) : nil
                entries.append(try SyncManifestEntry(
                    relativePath: relativePath,
                    itemType: itemType,
                    size: size,
                    modificationDate: modified,
                    contentHash: hash,
                    permissions: nil,
                    versionIdentifier: "\(size)-\(modified.timeIntervalSince1970)"
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped.append(relativePath)
            }
        }
        return Result(entries: entries.sorted { $0.relativePath < $1.relativePath }, skippedPaths: skipped)
    }

    nonisolated private static func enumeratedURLs(rootURL: URL, keys: [URLResourceKey]) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ManifestError.couldNotEnumerate
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard let relativePath = try? SharedPathValidator.safeRelativePath(from: rootURL, to: url) else {
                enumerator.skipDescendants()
                continue
            }
            if SharedItemIgnorePolicy.shouldIgnore(relativePath: relativePath) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            urls.append(url)
        }
        return urls
    }

    enum ManifestError: LocalizedError {
        case couldNotEnumerate
        var errorDescription: String? { "PeerNest could not enumerate the shared folder." }
    }
}
