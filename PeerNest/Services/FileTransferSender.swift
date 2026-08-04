//
//  FileTransferSender.swift
//  PeerNest
//

import Foundation

@MainActor
final class FileTransferSender {
    private let chunkSize: Int

    init(chunkSize: Int = PeerProtocolConstants.defaultFileChunkSize) {
        self.chunkSize = chunkSize
    }

    func send(
        fileURL: URL,
        operation: SyncOperation,
        destinationSharedFolderID: UUID,
        transport: PeerTransport,
        mappingID: UUID? = nil,
        negotiateResume: ((FileTransferStartPayload) async throws -> FileTransferResumeResponsePayload)? = nil,
        progress: @escaping (Double) -> Void
    ) async throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw SenderError.notRegularFile }
        let size = Int64(values.fileSize ?? 0)
        let hash = try await FileHashing.sha256(of: fileURL)
        let transferID = operation.id
        let destinationPath = operation.destinationRelativePath ?? operation.relativePath
        let start = FileTransferStartPayload(
            transferID: transferID,
            operationID: operation.id,
            sourceSharedFolderID: operation.sharedFolderID,
            destinationSharedFolderID: destinationSharedFolderID,
            sourceRelativePath: operation.relativePath,
            destinationRelativePath: destinationPath,
            size: size,
            sha256: hash,
            modificationDate: values.contentModificationDate ?? Date(),
            mappingID: mappingID,
            chunkSize: chunkSize
        )
        let resume: FileTransferResumeResponsePayload
        if let negotiateResume {
            resume = try await negotiateResume(start)
        } else {
            try await transport.send(.fileTransferStart, payload: start)
            resume = FileTransferResumeResponsePayload(
                transferID: transferID,
                accepted: false,
                nextExpectedOffset: 0,
                nextChunkIndex: 0
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let safeOffset = resume.accepted ? resume.nextExpectedOffset : 0
        guard safeOffset >= 0, safeOffset <= size,
              safeOffset % Int64(chunkSize) == 0 || safeOffset == size else {
            throw SenderError.invalidResumeOffset
        }
        try handle.seek(toOffset: UInt64(safeOffset))
        var sent = safeOffset
        var index = resume.accepted ? resume.nextChunkIndex : 0
        while !Task.isCancelled {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            try await transport.send(.fileChunk, payload: FileChunkPayload(
                transferID: transferID,
                index: index,
                data: data,
                offset: sent
            ))
            sent += Int64(data.count)
            index += 1
            progress(size == 0 ? 1 : min(Double(sent) / Double(size), 1))
        }
        try Task.checkCancellation()
        try await transport.send(.fileTransferComplete, payload: FileTransferCompletePayload(transferID: transferID))
        progress(1)
    }

    enum SenderError: LocalizedError {
        case notRegularFile
        case invalidResumeOffset
        var errorDescription: String? {
            switch self {
            case .notRegularFile: "Only regular files can be transferred."
            case .invalidResumeOffset: "The peer returned an invalid resume offset."
            }
        }
    }
}
