//
//  SharedFolder.swift
//  PeerNest
//

import Foundation

nonisolated enum SharedFolderAccessMode: String, Codable, Sendable {
    case readWrite
    case readOnly

    var title: String {
        switch self {
        case .readWrite: "Read & Write"
        case .readOnly: "Read Only"
        }
    }
}

enum SharedFolderSyncState: String, Codable, Sendable {
    case idle
    case monitoring
    case unavailable
    case error

    var title: String {
        switch self {
        case .idle: "Idle"
        case .monitoring: "Monitoring"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }
}

struct SharedFolder: Identifiable, Sendable {
    let id: UUID
    var displayName: String
    let rootURL: URL
    let createdAt: Date
    var isEnabled: Bool
    var accessMode: SharedFolderAccessMode
    var syncState: SharedFolderSyncState
}
