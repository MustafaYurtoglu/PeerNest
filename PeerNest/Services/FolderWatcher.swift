//
//  FolderWatcher.swift
//  PeerNest
//

import CoreServices
import Foundation

private struct RawFileSystemEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
}

private let folderWatcherCallback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
    guard let callbackInfo else { return }

    let watcher = Unmanaged<FolderWatcher>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var events: [RawFileSystemEvent] = []
    events.reserveCapacity(eventCount)

    for index in 0..<eventCount {
        guard let path = paths[index] else { continue }
        events.append(
            RawFileSystemEvent(
                path: String(cString: path),
                flags: eventFlags[index]
            )
        )
    }

    Task { @MainActor in
        watcher.receive(events)
    }
}

@MainActor
final class FolderWatcher {
    enum WatcherError: LocalizedError {
        case couldNotCreateStream
        case couldNotStartStream
        case eventsDropped

        var errorDescription: String? {
            switch self {
            case .couldNotCreateStream:
                "PeerNest could not create a folder monitoring stream."
            case .couldNotStartStream:
                "PeerNest could not start monitoring the shared folder."
            case .eventsDropped:
                "Some folder changes could not be recorded. Monitoring will continue."
            }
        }
    }

    private var stream: FSEventStreamRef?
    private var sharedFolderID: UUID?
    private var rootURL: URL?
    private var knownItems: [String: Bool] = [:]
    private var eventHandler: (([FileChangeEvent]) -> Void)?
    private var errorHandler: ((Error) -> Void)?

    var isMonitoring: Bool { stream != nil }

    func start(
        sharedFolderID: UUID,
        monitoring rootURL: URL,
        onEvents: @escaping ([FileChangeEvent]) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        if self.sharedFolderID == sharedFolderID,
           SharedPathValidator.isSameLocation(self.rootURL ?? rootURL, rootURL),
           stream != nil {
            return
        }

        stop()
        self.sharedFolderID = sharedFolderID
        self.rootURL = rootURL.standardizedFileURL
        knownItems = try Self.snapshot(rootURL: rootURL.standardizedFileURL)
        eventHandler = onEvents
        errorHandler = onError

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            resetHandlers()
            throw WatcherError.couldNotCreateStream
        }

        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            resetHandlers()
            throw WatcherError.couldNotStartStream
        }
        stream = newStream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        knownItems.removeAll()
        resetHandlers()
    }

    fileprivate func receive(_ rawEvents: [RawFileSystemEvent]) {
        guard stream != nil, let sharedFolderID, let rootURL else { return }

        if rawEvents.contains(where: { event in
            event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
        }) {
            errorHandler?(WatcherError.eventsDropped)
        }

        var events = rawEvents.compactMap {
            makeFileChangeEvent(
                from: $0,
                sharedFolderID: sharedFolderID,
                rootURL: rootURL
            )
        }
        if let currentItems = try? Self.snapshot(rootURL: rootURL) {
            let rawPaths = Set(events.map(\.relativePath))
            events.append(contentsOf: Self.inferredSnapshotEvents(
                previous: knownItems,
                current: currentItems,
                sharedFolderID: sharedFolderID,
                rootURL: rootURL
            ).filter { !rawPaths.contains($0.relativePath) })
            knownItems = currentItems
        }
        if !events.isEmpty {
            eventHandler?(events)
        }
    }

    /// APFS may report only the destination of a rename. A lightweight path
    /// snapshot preserves the vanished source as a journaled deletion.
    static func inferredSnapshotEvents(
        previous: [String: Bool],
        current: [String: Bool],
        sharedFolderID: UUID,
        rootURL: URL,
        timestamp: Date = Date()
    ) -> [FileChangeEvent] {
        let removed = previous.keys
            .filter { current[$0] == nil }
            .sorted {
                let leftDepth = $0.split(separator: "/").count
                let rightDepth = $1.split(separator: "/").count
                return leftDepth != rightDepth ? leftDepth > rightDepth : $0 < $1
            }
            .map { path in
                FileChangeEvent(
                    sharedFolderID: sharedFolderID,
                    relativePath: path,
                    localURL: rootURL.appendingPathComponent(path),
                    type: previous[path] == true ? .folderRemoved : .fileRemoved,
                    timestamp: timestamp,
                    origin: .local,
                    isDirectory: previous[path] == true
                )
            }
        let created = current.keys
            .filter { previous[$0] == nil }
            .sorted {
                let leftDepth = $0.split(separator: "/").count
                let rightDepth = $1.split(separator: "/").count
                return leftDepth != rightDepth ? leftDepth < rightDepth : $0 < $1
            }
            .map { path in
                FileChangeEvent(
                    sharedFolderID: sharedFolderID,
                    relativePath: path,
                    localURL: rootURL.appendingPathComponent(path),
                    type: current[path] == true ? .folderCreated : .fileCreated,
                    timestamp: timestamp,
                    origin: .local,
                    isDirectory: current[path] == true
                )
            }
        return removed + created
    }

    private static func snapshot(rootURL: URL) throws -> [String: Bool] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw WatcherError.couldNotCreateStream
        }
        var result: [String: Bool] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard let relativePath = try? SharedPathValidator.safeRelativePath(from: rootURL, to: url) else {
                enumerator.skipDescendants()
                continue
            }
            if SharedItemIgnorePolicy.shouldIgnore(relativePath: relativePath) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true { result[relativePath] = true }
            else if values.isRegularFile == true { result[relativePath] = false }
        }
        return result
    }

    private func makeFileChangeEvent(
        from event: RawFileSystemEvent,
        sharedFolderID: UUID,
        rootURL: URL
    ) -> FileChangeEvent? {
        let localURL = URL(fileURLWithPath: event.path)
        guard let relativePath = try? SharedPathValidator.safeRelativePath(from: rootURL, to: localURL),
              !SharedItemIgnorePolicy.shouldIgnore(relativePath: relativePath) else {
            return nil
        }

        let flags = event.flags
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let type: FileChangeEvent.EventType

        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            type = .itemRenamed
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            type = isDirectory ? .folderCreated : .fileCreated
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            type = isDirectory ? .folderRemoved : .fileRemoved
        } else if !isDirectory, isModification(flags) {
            type = .fileModified
        } else {
            return nil
        }

        return FileChangeEvent(
            sharedFolderID: sharedFolderID,
            relativePath: relativePath,
            localURL: localURL,
            type: type,
            origin: .local,
            isDirectory: isDirectory
        )
    }

    private func isModification(_ flags: FSEventStreamEventFlags) -> Bool {
        let modificationFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
                | kFSEventStreamEventFlagItemXattrMod
        )
        return flags & modificationFlags != 0
    }

    private func resetHandlers() {
        sharedFolderID = nil
        rootURL = nil
        eventHandler = nil
        errorHandler = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
