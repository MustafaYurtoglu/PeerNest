import Foundation

struct FinderSharedFolderRecord: Codable, Equatable, Sendable {
    let id: UUID
    let rootPath: String
    let isEnabled: Bool
    let state: FinderBadgeState
    let updatedAt: Date

    init(
        id: UUID,
        rootURL: URL,
        isEnabled: Bool,
        state: FinderBadgeState,
        updatedAt: Date = Date()
    ) {
        self.id = id
        rootPath = SharedPathValidator.canonicalURL(rootURL).path
        self.isEnabled = isEnabled
        self.state = state
        self.updatedAt = updatedAt
    }

    var rootURL: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }
}

struct FinderSharedStateSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumAge: TimeInterval = 5 * 60

    let version: Int
    let generatedAt: Date
    let folders: [FinderSharedFolderRecord]

    init(
        version: Int = currentVersion,
        generatedAt: Date = Date(),
        folders: [FinderSharedFolderRecord]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.folders = folders
    }

    func isCompatible() -> Bool {
        version == Self.currentVersion
    }

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > Self.maximumAge
    }

    func badgeState(for folderID: UUID, now: Date = Date()) -> FinderBadgeState {
        guard isCompatible(), !isStale(now: now) else { return .unknown }
        return folders.first(where: { $0.id == folderID })?.state ?? .unknown
    }
}

enum FinderSharedStateReadResult {
    case missing
    case valid(FinderSharedStateSnapshot)
    case corrupt(Error)
}

final class FinderSharedStateSnapshotStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            "The PeerNest App Group container is unavailable."
        }
    }

    private let fileManager: FileManager
    private let snapshotURL: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(containerURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        guard let root = containerURL ?? fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: PeerNestSharedConfiguration.appGroupIdentifier
        ) else {
            throw StoreError.appGroupUnavailable
        }
        snapshotURL = root.appendingPathComponent("FinderSharedStateSnapshot.plist")
    }

    func write(_ snapshot: FinderSharedStateSnapshot) throws {
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    func read() throws -> FinderSharedStateSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        return try decoder.decode(
            FinderSharedStateSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
    }

    func readDefensively() -> FinderSharedStateReadResult {
        do {
            guard let snapshot = try read() else { return .missing }
            guard snapshot.isCompatible() else {
                return .corrupt(FinderSharedStateSnapshotError.unsupportedVersion(snapshot.version))
            }
            return .valid(snapshot)
        } catch {
            return .corrupt(error)
        }
    }
}

private enum FinderSharedStateSnapshotError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported Finder shared-state snapshot version: \(version)."
        }
    }
}
