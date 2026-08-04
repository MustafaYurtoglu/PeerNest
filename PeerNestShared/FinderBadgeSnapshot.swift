import Foundation

enum FinderBadgeState: String, Codable, CaseIterable, Sendable {
    case upToDate, syncing, offlineChangesPending, conflict, paused, error, unknown

    var badgeIdentifier: String { "peernest.\(rawValue)" }
}

struct FinderFolderBadgeRecord: Codable, Equatable, Sendable {
    let sharedFolderID: UUID
    let state: FinderBadgeState
    let targetedRelativePaths: [String: FinderBadgeState]
}

struct FinderBadgeSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumAge: TimeInterval = 5 * 60

    let version: Int
    let generatedAt: Date
    let folders: [FinderFolderBadgeRecord]

    init(version: Int = currentVersion, generatedAt: Date = Date(), folders: [FinderFolderBadgeRecord]) {
        self.version = version
        self.generatedAt = generatedAt
        self.folders = folders
    }

    func state(for sharedFolderID: UUID, now: Date = Date()) -> FinderBadgeState {
        guard version == Self.currentVersion,
              now.timeIntervalSince(generatedAt) <= Self.maximumAge else { return .unknown }
        return folders.first { $0.sharedFolderID == sharedFolderID }?.state ?? .unknown
    }
}

final class FinderBadgeSnapshotStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case appGroupUnavailable
        var errorDescription: String? { "The PeerNest App Group container is unavailable." }
    }

    private let snapshotURL: URL
    private let fileManager: FileManager
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(containerURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        guard let root = containerURL ?? fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: PeerNestSharedConfiguration.appGroupIdentifier
        ) else { throw StoreError.appGroupUnavailable }
        snapshotURL = root.appendingPathComponent("FinderBadgeSnapshot.plist")
    }

    func write(_ snapshot: FinderBadgeSnapshot) throws {
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    func read() throws -> FinderBadgeSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        return try decoder.decode(FinderBadgeSnapshot.self, from: Data(contentsOf: snapshotURL))
    }
}
