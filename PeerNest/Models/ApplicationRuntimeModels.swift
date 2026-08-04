import Foundation

enum OverallSyncState: String, CaseIterable, Sendable {
    case idle, upToDate, syncing, offlineChangesPending, reconciling
    case conflictsNeedAttention, paused, error

    var title: String {
        switch self {
        case .idle: "Idle"
        case .upToDate: "Up to Date"
        case .syncing: "Syncing"
        case .offlineChangesPending: "Offline Changes Pending"
        case .reconciling: "Reconciling"
        case .conflictsNeedAttention: "Conflicts Need Attention"
        case .paused: "Paused"
        case .error: "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .upToDate: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offlineChangesPending: "clock.badge.exclamationmark"
        case .reconciling: "arrow.trianglehead.2.clockwise.rotate.90"
        case .conflictsNeedAttention: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }
}

enum LocalNetworkState: Equatable, Sendable {
    case available, unavailable, reconnecting

    var title: String {
        switch self {
        case .available: "Local Network Available"
        case .unavailable: "Local Network Unavailable"
        case .reconnecting: "Reconnecting"
        }
    }
}

struct ActiveTransferPresentation: Equatable, Sendable {
    enum Direction: String, Sendable { case upload, download }
    let relativePath: String
    let direction: Direction
    let progress: Double
    let canCancelSafely: Bool
}

struct MenuBarState: Equatable, Sendable {
    let overallState: OverallSyncState
    let onlineTrustedPeerCount: Int
    let offlineTrustedPeerCount: Int
    let connectedPeerNames: [String]
    let pendingOperationCount: Int
    let unresolvedConflictCount: Int
    let activeTransfer: ActiveTransferPresentation?
    let lastSuccessfulSync: Date?
}

enum SyncStateAggregator {
    static func state(
        isPaused: Bool,
        latestError: String?,
        unresolvedConflictCount: Int,
        isReconciling: Bool,
        transferProgress: Double?,
        pendingOperationCount: Int,
        isConnected: Bool,
        hasEnabledFolders: Bool
    ) -> OverallSyncState {
        if isPaused { return .paused }
        if unresolvedConflictCount > 0 { return .conflictsNeedAttention }
        if latestError != nil { return .error }
        if isReconciling { return .reconciling }
        if transferProgress != nil { return .syncing }
        if pendingOperationCount > 0 { return .offlineChangesPending }
        if isConnected && hasEnabledFolders { return .upToDate }
        return .idle
    }
}

enum BuildConfiguration {
    #if DEBUG
    static let isDebug = true
    static let allowsLocalhostControls = true
    static let allowsPlaintextTransport = true
    #else
    static let isDebug = false
    static let allowsLocalhostControls = false
    static let allowsPlaintextTransport = false
    #endif
}
