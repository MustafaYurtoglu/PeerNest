//
//  FileChangeEvent.swift
//  PeerNest
//

import Foundation

struct FileChangeEvent: Identifiable, Sendable {
    enum EventType: Sendable, Equatable {
        case fileCreated
        case fileModified
        case fileRemoved
        case itemRenamed
        case folderCreated
        case folderRemoved

        var title: String {
            switch self {
            case .fileCreated: "File created"
            case .fileModified: "File modified"
            case .fileRemoved: "File removed"
            case .itemRenamed: "Item renamed"
            case .folderCreated: "Folder created"
            case .folderRemoved: "Folder removed"
            }
        }

        var symbolName: String {
            switch self {
            case .fileCreated: "doc.badge.plus"
            case .fileModified: "pencil"
            case .fileRemoved: "doc.badge.minus"
            case .itemRenamed: "character.cursor.ibeam"
            case .folderCreated: "folder.badge.plus"
            case .folderRemoved: "folder.badge.minus"
            }
        }
    }

    enum Origin: Sendable {
        case local
        case peerNestGenerated
    }

    let id: UUID
    let sharedFolderID: UUID
    let relativePath: String
    let localURL: URL
    let type: EventType
    let timestamp: Date
    let origin: Origin
    let isDirectory: Bool

    init(
        id: UUID = UUID(),
        sharedFolderID: UUID,
        relativePath: String,
        localURL: URL,
        type: EventType,
        timestamp: Date = Date(),
        origin: Origin = .local,
        isDirectory: Bool
    ) {
        self.id = id
        self.sharedFolderID = sharedFolderID
        self.relativePath = relativePath
        self.localURL = localURL
        self.type = type
        self.timestamp = timestamp
        self.origin = origin
        self.isDirectory = isDirectory
    }
}
