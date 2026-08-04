//
//  SharedFolderPersistenceService.swift
//  PeerNest
//

import Foundation

struct PersistedSharedFolder: Codable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let createdAt: Date
    let isEnabled: Bool
    let accessMode: SharedFolderAccessMode
}

@MainActor
final class SharedFolderPersistenceService {
    private let defaults: UserDefaults
    private let storageKey = "sharedFolders.v1"
    private let legacyBookmarkKey = "selectedFolderSecurityScopedBookmark"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [PersistedSharedFolder] {
        if let data = defaults.data(forKey: storageKey) {
            return try decoder.decode([PersistedSharedFolder].self, from: data)
        }

        guard let legacyBookmark = defaults.data(forKey: legacyBookmarkKey) else {
            return []
        }
        return [
            PersistedSharedFolder(
                id: UUID(),
                displayName: "Shared Folder",
                bookmarkData: legacyBookmark,
                createdAt: Date(),
                isEnabled: true,
                accessMode: .readWrite
            )
        ]
    }

    func save(_ folders: [PersistedSharedFolder]) throws {
        defaults.set(try encoder.encode(folders), forKey: storageKey)
        defaults.removeObject(forKey: legacyBookmarkKey)
    }
}
