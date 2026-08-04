//
//  FileTransferReceiver.swift
//  PeerNest
//

import CryptoKit
import Foundation

actor FileTransferReceiver {
    enum TransferError: LocalizedError, Equatable {
        case unknownTransfer
        case outOfOrderChunk
        case sizeMismatch(expected: Int64, actual: Int64)
        case hashMismatch

        var errorDescription: String? {
            switch self {
            case .unknownTransfer: "The file transfer was not started."
            case .outOfOrderChunk: "A file transfer chunk arrived out of order."
            case let .sizeMismatch(expected, actual): "File size verification failed (expected \(expected), received \(actual))."
            case .hashMismatch: "File hash verification failed."
            }
        }
    }

    private struct Session {
        let payload: FileTransferStartPayload
        let rootURL: URL
        let temporaryURL: URL
        let handle: FileHandle
        var receivedSize: Int64
        var nextChunkIndex: Int
    }

    private let fileManager: FileManager
    private let registry: AppliedOperationRegistry
    private let repository: RecoveryRepository?
    private var sessions: [UUID: Session] = [:]

    init(
        fileManager: FileManager = .default,
        registry: AppliedOperationRegistry,
        repository: RecoveryRepository? = nil
    ) {
        self.fileManager = fileManager
        self.registry = registry
        self.repository = repository
    }

    @discardableResult
    func start(_ payload: FileTransferStartPayload, rootURL: URL) async throws -> FileTransferResumeResponsePayload {
        _ = try SharedPathValidator.destinationURL(in: rootURL, relativePath: payload.destinationRelativePath)
        let staging = repository?.stagingURL
            ?? rootURL.appendingPathComponent(SharedItemIgnorePolicy.internalMetadataDirectoryName, isDirectory: true)
                .appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporaryURL = staging.appendingPathComponent("\(payload.transferID.uuidString).partial")
        let expectedToken = Self.resumeToken(for: payload)
        let prior = await repository?.transfer(id: payload.transferID)
        let mayResume = prior?.totalSize == payload.size
            && prior?.expectedFinalHash == payload.sha256
            && prior?.sourceModificationDate == payload.modificationDate
            && prior?.resumeToken == expectedToken
            && fileManager.fileExists(atPath: temporaryURL.path)
        if !mayResume, fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        if !fileManager.fileExists(atPath: temporaryURL.path) {
            fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        }
        let existingSize = mayResume
            ? Int64((try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            : 0
        guard existingSize <= payload.size else {
            try? fileManager.removeItem(at: temporaryURL)
            throw TransferError.sizeMismatch(expected: payload.size, actual: existingSize)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.seek(toOffset: UInt64(existingSize))
        let nextIndex = mayResume ? prior?.nextChunkIndex ?? 0 : 0
        sessions[payload.transferID] = Session(
            payload: payload,
            rootURL: rootURL,
            temporaryURL: temporaryURL,
            handle: handle,
            receivedSize: existingSize,
            nextChunkIndex: nextIndex
        )
        if let repository, let mappingID = payload.mappingID {
            let relative = try SharedPathValidator.safeRelativePath(from: repository.rootURL, to: temporaryURL)
            try await repository.saveTransfer(ResumableTransferState(
                transferID: payload.transferID,
                mappingID: mappingID,
                operationID: payload.operationID,
                totalSize: payload.size,
                chunkSize: payload.chunkSize ?? PeerProtocolConstants.defaultFileChunkSize,
                nextExpectedOffset: existingSize,
                nextChunkIndex: nextIndex,
                stagingRelativePath: relative,
                expectedFinalHash: payload.sha256,
                sourceModificationDate: payload.modificationDate,
                expirationDate: Date().addingTimeInterval(7 * 86_400),
                resumeToken: expectedToken
            ))
        }
        return FileTransferResumeResponsePayload(
            transferID: payload.transferID,
            accepted: mayResume,
            nextExpectedOffset: existingSize,
            nextChunkIndex: nextIndex
        )
    }

    func append(_ chunk: FileChunkPayload) async throws {
        guard var session = sessions[chunk.transferID] else { throw TransferError.unknownTransfer }
        guard chunk.index == session.nextChunkIndex else { throw TransferError.outOfOrderChunk }
        if let offset = chunk.offset, offset != session.receivedSize { throw TransferError.outOfOrderChunk }
        let nextSize = session.receivedSize + Int64(chunk.data.count)
        guard nextSize <= session.payload.size else {
            throw TransferError.sizeMismatch(expected: session.payload.size, actual: nextSize)
        }
        try session.handle.write(contentsOf: chunk.data)
        session.receivedSize = nextSize
        session.nextChunkIndex += 1
        sessions[chunk.transferID] = session
        if let repository, var state = await repository.transfer(id: chunk.transferID) {
            state.nextExpectedOffset = session.receivedSize
            state.nextChunkIndex = session.nextChunkIndex
            try await repository.saveTransfer(state)
        }
    }

    @discardableResult
    func complete(transferID: UUID) async throws -> FileTransferStartPayload {
        guard let session = sessions.removeValue(forKey: transferID) else { throw TransferError.unknownTransfer }
        do {
            try session.handle.close()
            guard session.receivedSize == session.payload.size else {
                throw TransferError.sizeMismatch(expected: session.payload.size, actual: session.receivedSize)
            }
            let hash = try await FileHashing.sha256(of: session.temporaryURL)
            guard hash == session.payload.sha256 else { throw TransferError.hashMismatch }

            let destination = try SharedPathValidator.destinationURL(
                in: session.rootURL,
                relativePath: session.payload.destinationRelativePath
            )
            let parent = destination.deletingLastPathComponent()
            guard SharedPathValidator.contains(root: session.rootURL, candidate: parent) else {
                throw SharedPathValidationError.symbolicLinkEscapesRoot
            }
            guard await registry.claimOperation(session.payload.operationID) else {
                try? fileManager.removeItem(at: session.temporaryURL)
                return session.payload
            }
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            await registry.register(
                operationID: session.payload.operationID,
                sharedFolderID: session.payload.destinationSharedFolderID,
                relativePath: session.payload.destinationRelativePath,
                expectedHash: hash
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: session.temporaryURL)
            } else {
                try fileManager.moveItem(at: session.temporaryURL, to: destination)
            }
            try? fileManager.setAttributes(
                [.modificationDate: session.payload.modificationDate],
                ofItemAtPath: destination.path
            )
            try? await repository?.removeTransfer(id: transferID)
            return session.payload
        } catch {
            try? session.handle.close()
            try? fileManager.removeItem(at: session.temporaryURL)
            try? await repository?.removeTransfer(id: transferID)
            throw error
        }
    }

    func cancel(transferID: UUID) {
        guard let session = sessions.removeValue(forKey: transferID) else { return }
        try? session.handle.close()
        try? fileManager.removeItem(at: session.temporaryURL)
        if let repository { Task { try? await repository.removeTransfer(id: transferID) } }
    }

    func cancelAll() {
        for transferID in Array(sessions.keys) { cancel(transferID: transferID) }
    }

    func suspendAll() {
        for transferID in Array(sessions.keys) {
            guard let session = sessions.removeValue(forKey: transferID) else { continue }
            try? session.handle.close()
        }
    }

    func hasActiveTransfer(_ transferID: UUID) -> Bool { sessions[transferID] != nil }

    private nonisolated static func resumeToken(for payload: FileTransferStartPayload) -> String {
        let material = "\(payload.mappingID?.uuidString ?? "legacy")|\(payload.operationID.uuidString)|\(payload.size)|\(payload.sha256)|\(payload.modificationDate.timeIntervalSince1970)"
        return FileTransferResumeToken.hash(material)
    }
}

private enum FileTransferResumeToken {
    nonisolated static func hash(_ value: String) -> String {
        // The token is integrity-bound metadata sent only inside the authenticated session.
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
