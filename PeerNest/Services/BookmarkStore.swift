//
//  BookmarkStore.swift
//  PeerNest
//

import Foundation

struct BookmarkAccessGrant {
    let url: URL
    let bookmarkData: Data
}

@MainActor
protocol BookmarkStoring {
    func createAndAccess(_ url: URL) throws -> BookmarkAccessGrant
    func resolveAndAccess(_ bookmarkData: Data) throws -> BookmarkAccessGrant
    func stopAccessing(_ url: URL)
}

@MainActor
final class BookmarkStore: BookmarkStoring {
    enum BookmarkError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "PeerNest could not establish lasting access to this folder. Please select it in PeerNest to grant access."
        }
    }

    func createAndAccess(_ url: URL) throws -> BookmarkAccessGrant {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }
        return BookmarkAccessGrant(url: url, bookmarkData: bookmarkData)
    }

    func resolveAndAccess(_ bookmarkData: Data) throws -> BookmarkAccessGrant {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }

        do {
            let currentBookmark = isStale
                ? try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                : bookmarkData
            return BookmarkAccessGrant(url: url, bookmarkData: currentBookmark)
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

#if DEBUG
/// Explicitly unscoped storage for isolated localhost integration roots only.
/// The containing app sandbox remains authoritative; production builds never compile this type.
@MainActor
final class DebugUnscopedBookmarkStore: BookmarkStoring {
    enum StoreError: Error { case invalidBookmark }

    func createAndAccess(_ url: URL) throws -> BookmarkAccessGrant {
        BookmarkAccessGrant(
            url: url.standardizedFileURL,
            bookmarkData: Data(url.standardizedFileURL.path.utf8)
        )
    }

    func resolveAndAccess(_ bookmarkData: Data) throws -> BookmarkAccessGrant {
        guard let path = String(data: bookmarkData, encoding: .utf8), path.hasPrefix("/") else {
            throw StoreError.invalidBookmark
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return BookmarkAccessGrant(url: url, bookmarkData: bookmarkData)
    }

    func stopAccessing(_ url: URL) {}
}
#endif
