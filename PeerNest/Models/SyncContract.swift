//
//  SyncContract.swift
//  PeerNest
//

import Foundation

nonisolated struct SyncManifestEntry: Codable, Equatable, Sendable {
    enum ItemType: String, Codable, Sendable {
        case file
        case directory
        case symbolicLink
    }

    let relativePath: String
    let itemType: ItemType
    let size: Int64
    let modificationDate: Date
    let contentHash: String?
    let permissions: UInt16?
    let versionIdentifier: String?

    init(
        relativePath: String,
        itemType: ItemType,
        size: Int64,
        modificationDate: Date,
        contentHash: String? = nil,
        permissions: UInt16? = nil,
        versionIdentifier: String? = nil
    ) throws {
        self.relativePath = try SharedPathValidator.validatedRelativePath(relativePath)
        self.itemType = itemType
        self.size = size
        self.modificationDate = modificationDate
        self.contentHash = contentHash
        self.permissions = permissions
        self.versionIdentifier = versionIdentifier
    }
}

nonisolated struct SyncOperation: Codable, Identifiable, Equatable, Sendable {
    enum OperationType: String, Codable, Sendable {
        case createFile
        case updateFile
        case createDirectory
        case rename
        case move
        case delete
    }

    let id: UUID
    let sharedFolderID: UUID
    let type: OperationType
    let relativePath: String
    let destinationRelativePath: String?

    init(
        id: UUID = UUID(),
        sharedFolderID: UUID,
        type: OperationType,
        relativePath: String,
        destinationRelativePath: String? = nil
    ) throws {
        self.id = id
        self.sharedFolderID = sharedFolderID
        self.type = type
        self.relativePath = try SharedPathValidator.validatedRelativePath(relativePath)
        if let destinationRelativePath {
            self.destinationRelativePath = try SharedPathValidator.validatedRelativePath(destinationRelativePath)
        } else {
            self.destinationRelativePath = nil
        }
    }
}
