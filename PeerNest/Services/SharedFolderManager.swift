//
//  SharedFolderManager.swift
//  PeerNest
//

import Foundation

@MainActor
final class SharedFolderManager {
    enum ManagerError: LocalizedError {
        case notDirectory
        case folderNotFound

        var errorDescription: String? {
            switch self {
            case .notDirectory: "Only folders can be shared with PeerNest."
            case .folderNotFound: "The shared folder could not be found."
            }
        }
    }

    private(set) var sharedFolders: [SharedFolder] = []
    var onFoldersChanged: (([SharedFolder]) -> Void)?
    var onEvents: (([FileChangeEvent]) -> Void)?
    var onError: ((Error) -> Void)?

    private let bookmarkStore: any BookmarkStoring
    private let persistence: SharedFolderPersistenceService
    private var bookmarkDataByID: [UUID: Data] = [:]
    private var accessedURLByID: [UUID: URL] = [:]
    private var watchersByID: [UUID: FolderWatcher] = [:]

    init() {
        bookmarkStore = BookmarkStore()
        persistence = SharedFolderPersistenceService()
    }

    init(bookmarkStore: any BookmarkStoring, persistence: SharedFolderPersistenceService) {
        self.bookmarkStore = bookmarkStore
        self.persistence = persistence
    }

    func restore() {
        stopAll()
        sharedFolders.removeAll()
        bookmarkDataByID.removeAll()

        do {
            for record in try persistence.load() {
                do {
                    let grant = try bookmarkStore.resolveAndAccess(record.bookmarkData)
                    let rootURL = SharedPathValidator.canonicalURL(grant.url)
                    try validateDirectory(rootURL)
                    try SharedFolderOverlapPolicy.validate(
                        candidate: rootURL,
                        existingRoots: sharedFolders.map(\.rootURL)
                    )

                    let folder = SharedFolder(
                        id: record.id,
                        displayName: rootURL.lastPathComponent.isEmpty
                            ? record.displayName
                            : rootURL.lastPathComponent,
                        rootURL: rootURL,
                        createdAt: record.createdAt,
                        isEnabled: record.isEnabled,
                        accessMode: record.accessMode,
                        syncState: record.isEnabled ? .idle : .idle
                    )
                    sharedFolders.append(folder)
                    bookmarkDataByID[folder.id] = grant.bookmarkData
                    accessedURLByID[folder.id] = grant.url

                    if folder.isEnabled {
                        startWatcher(for: folder.id)
                    } else {
                        releaseAccess(for: folder.id)
                    }
                } catch {
                    onError?(error)
                }
            }
            try persist()
        } catch {
            onError?(error)
        }
        notifyFoldersChanged()
    }

    @discardableResult
    func addFolder(
        at url: URL,
        suppliedBookmarkData: Data? = nil,
        accessMode: SharedFolderAccessMode = .readWrite
    ) throws -> SharedFolder {
        let grant = try suppliedBookmarkData.map(bookmarkStore.resolveAndAccess)
            ?? bookmarkStore.createAndAccess(url)
        let rootURL = SharedPathValidator.canonicalURL(grant.url)

        do {
            try validateDirectory(rootURL)
            try SharedFolderOverlapPolicy.validate(
                candidate: rootURL,
                existingRoots: sharedFolders.map(\.rootURL)
            )
        } catch {
            bookmarkStore.stopAccessing(grant.url)
            throw error
        }

        let folder = SharedFolder(
            id: UUID(),
            displayName: rootURL.lastPathComponent,
            rootURL: rootURL,
            createdAt: Date(),
            isEnabled: true,
            accessMode: accessMode,
            syncState: .idle
        )
        sharedFolders.append(folder)
        bookmarkDataByID[folder.id] = grant.bookmarkData
        accessedURLByID[folder.id] = grant.url
        startWatcher(for: folder.id)
        try persist()
        notifyFoldersChanged()
        return sharedFolders.first(where: { $0.id == folder.id }) ?? folder
    }

    func removeFolder(id: UUID) throws {
        guard let index = sharedFolders.firstIndex(where: { $0.id == id }) else {
            throw ManagerError.folderNotFound
        }
        stopWatcher(for: id)
        releaseAccess(for: id)
        sharedFolders.remove(at: index)
        bookmarkDataByID[id] = nil
        try persist()
        notifyFoldersChanged()
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) throws {
        guard let index = sharedFolders.firstIndex(where: { $0.id == id }) else {
            throw ManagerError.folderNotFound
        }
        guard sharedFolders[index].isEnabled != isEnabled else { return }

        if isEnabled {
            guard let bookmarkData = bookmarkDataByID[id] else {
                throw ManagerError.folderNotFound
            }
            let grant = try bookmarkStore.resolveAndAccess(bookmarkData)
            bookmarkDataByID[id] = grant.bookmarkData
            accessedURLByID[id] = grant.url
            sharedFolders[index].isEnabled = true
            sharedFolders[index].syncState = .idle
            startWatcher(for: id)
        } else {
            stopWatcher(for: id)
            releaseAccess(for: id)
            sharedFolders[index].isEnabled = false
            sharedFolders[index].syncState = .idle
        }
        try persist()
        notifyFoldersChanged()
    }

    func folder(matchingRootURL url: URL) -> SharedFolder? {
        sharedFolders.first { SharedPathValidator.isSameLocation($0.rootURL, url) }
    }

    func folder(id: UUID) -> SharedFolder? {
        sharedFolders.first { $0.id == id }
    }

    func folder(containing url: URL) -> SharedFolder? {
        sharedFolders.first {
            SharedPathValidator.contains(root: $0.rootURL, candidate: url)
        }
    }

    func safeRelativePath(for url: URL, in folderID: UUID) throws -> String {
        guard let folder = sharedFolders.first(where: { $0.id == folderID }) else {
            throw ManagerError.folderNotFound
        }
        return try SharedPathValidator.safeRelativePath(from: folder.rootURL, to: url)
    }

    func destinationURL(for relativePath: String, in folderID: UUID) throws -> URL {
        guard let folder = sharedFolders.first(where: { $0.id == folderID }) else {
            throw ManagerError.folderNotFound
        }
        return try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: relativePath)
    }

    func stopAll() {
        for watcher in watchersByID.values {
            watcher.stop()
        }
        watchersByID.removeAll()
        for url in accessedURLByID.values {
            bookmarkStore.stopAccessing(url)
        }
        accessedURLByID.removeAll()
    }

    private func startWatcher(for id: UUID) {
        guard watchersByID[id] == nil,
              let folder = sharedFolders.first(where: { $0.id == id }),
              folder.isEnabled else {
            return
        }

        let watcher = FolderWatcher()
        do {
            try watcher.start(
                sharedFolderID: folder.id,
                monitoring: folder.rootURL,
                onEvents: { [weak self] events in self?.onEvents?(events) },
                onError: { [weak self] error in self?.handleWatcherError(error, folderID: id) }
            )
            watchersByID[id] = watcher
            updateSyncState(.monitoring, for: id)
        } catch {
            updateSyncState(.error, for: id)
            onError?(error)
        }
    }

    private func stopWatcher(for id: UUID) {
        watchersByID[id]?.stop()
        watchersByID[id] = nil
    }

    private func releaseAccess(for id: UUID) {
        if let url = accessedURLByID.removeValue(forKey: id) {
            bookmarkStore.stopAccessing(url)
        }
    }

    private func handleWatcherError(_ error: Error, folderID: UUID) {
        updateSyncState(.error, for: folderID)
        onError?(error)
    }

    private func updateSyncState(_ state: SharedFolderSyncState, for id: UUID) {
        guard let index = sharedFolders.firstIndex(where: { $0.id == id }) else { return }
        sharedFolders[index].syncState = state
        notifyFoldersChanged()
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw ManagerError.notDirectory }
    }

    private func persist() throws {
        let records = sharedFolders.compactMap { folder -> PersistedSharedFolder? in
            guard let bookmarkData = bookmarkDataByID[folder.id] else { return nil }
            return PersistedSharedFolder(
                id: folder.id,
                displayName: folder.displayName,
                bookmarkData: bookmarkData,
                createdAt: folder.createdAt,
                isEnabled: folder.isEnabled,
                accessMode: folder.accessMode
            )
        }
        try persistence.save(records)
    }

    private func notifyFoldersChanged() {
        onFoldersChanged?(sharedFolders)
    }
}
