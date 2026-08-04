//
//  ShareMapping.swift
//  PeerNest
//

import Foundation

nonisolated struct ShareMapping: Identifiable, Codable, Equatable, Sendable {
    enum LocalRole: String, Codable, Sendable {
        case owner
        case receiver
    }

    let id: UUID
    let localSharedFolderID: UUID
    let remoteSharedFolderID: UUID
    let remotePeerID: UUID
    var accessMode: SharedFolderAccessMode
    var isEnabled: Bool
    var localRole: LocalRole
    var remoteDisplayName: String?

    init(
        id: UUID = UUID(),
        localSharedFolderID: UUID,
        remoteSharedFolderID: UUID,
        remotePeerID: UUID,
        accessMode: SharedFolderAccessMode = .readWrite,
        isEnabled: Bool = true,
        localRole: LocalRole = .owner,
        remoteDisplayName: String? = nil
    ) {
        self.id = id
        self.localSharedFolderID = localSharedFolderID
        self.remoteSharedFolderID = remoteSharedFolderID
        self.remotePeerID = remotePeerID
        self.accessMode = accessMode
        self.isEnabled = isEnabled
        self.localRole = localRole
        self.remoteDisplayName = remoteDisplayName
    }
}

enum InitialSyncState: String, Sendable {
    case idle
    case buildingManifest
    case comparing
    case synchronizing
    case completed
    case failed
}

struct SyncActivity: Identifiable, Sendable {
    enum Kind: Sendable { case information, sent, received, conflict, failure }
    let id: UUID
    let timestamp: Date
    let message: String
    let kind: Kind

    init(id: UUID = UUID(), timestamp: Date = Date(), message: String, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.kind = kind
    }
}
