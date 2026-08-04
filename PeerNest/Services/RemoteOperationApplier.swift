//
//  RemoteOperationApplier.swift
//  PeerNest
//

import Foundation

actor RemoteOperationApplier {
    enum ApplicationError: LocalizedError, Equatable {
        case cannotDeleteSharedRoot
        case unsupportedFileOperation
        case destinationRequired

        var errorDescription: String? {
            switch self {
            case .cannotDeleteSharedRoot: "The shared folder root cannot be deleted."
            case .unsupportedFileOperation: "File content must be applied through a verified transfer."
            case .destinationRequired: "A move or rename operation requires a destination path."
            }
        }
    }

    private let fileManager: FileManager
    private let registry: AppliedOperationRegistry

    init(fileManager: FileManager = .default, registry: AppliedOperationRegistry) {
        self.fileManager = fileManager
        self.registry = registry
    }

    @discardableResult
    func apply(_ payload: NetworkSyncOperationPayload, rootURL: URL) async throws -> Bool {
        let operation = payload.operation
        guard await registry.claimOperation(operation.id) else { return false }
        let source = try destination(rootURL: rootURL, relativePath: operation.relativePath)

        switch operation.type {
        case .createDirectory:
            await registry.register(
                operationID: operation.id,
                sharedFolderID: payload.destinationSharedFolderID,
                relativePath: operation.relativePath,
                expectedHash: nil
            )
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        case .rename, .move:
            guard let destinationPath = operation.destinationRelativePath else {
                throw ApplicationError.destinationRequired
            }
            let target = try destination(rootURL: rootURL, relativePath: destinationPath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            await registry.register(
                operationID: operation.id,
                sharedFolderID: payload.destinationSharedFolderID,
                relativePath: destinationPath,
                expectedHash: nil
            )
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: source, to: target)
        case .delete:
            await registry.register(
                operationID: operation.id,
                sharedFolderID: payload.destinationSharedFolderID,
                relativePath: operation.relativePath,
                expectedHash: nil
            )
            if fileManager.fileExists(atPath: source.path) { try fileManager.removeItem(at: source) }
        case .createFile, .updateFile:
            throw ApplicationError.unsupportedFileOperation
        }
        return true
    }

    func validateDeletion(relativePath: String, rootURL: URL) throws {
        guard !relativePath.isEmpty else { throw ApplicationError.cannotDeleteSharedRoot }
        _ = try destination(rootURL: rootURL, relativePath: relativePath)
    }

    private func destination(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty else { throw ApplicationError.cannotDeleteSharedRoot }
        return try SharedPathValidator.destinationURL(in: rootURL, relativePath: relativePath)
    }
}
