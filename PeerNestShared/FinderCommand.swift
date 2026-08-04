//
//  FinderCommand.swift
//  PeerNest
//

import Foundation

enum PeerNestSharedConfiguration {
    static let appGroupIdentifier = "group.com.mustafayurtoglu.PeerNest"
    static let mainAppBundleIdentifier = "com.mustafayurtoglu.PeerNest"
}

enum FinderCommandType: String, Codable, Sendable {
    case shareFolder
    case stopSharing
    case showInApp
    case pauseSync
    case resumeSync
    case viewSyncStatus
}

struct FinderCommand: Identifiable, Codable, Sendable {
    let id: UUID
    let type: FinderCommandType
    let selectedURL: URL
    let bookmarkData: Data?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        type: FinderCommandType,
        selectedURL: URL,
        bookmarkData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.selectedURL = selectedURL
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }
}
