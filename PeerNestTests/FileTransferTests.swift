import Foundation
import Testing
@testable import PeerNest

@MainActor @Test func resumeResponseBypassesSerializedMessageQueue() {
    #expect(PeerSyncCoordinator.bypassesSerializedMessageProcessing(.fileTransferResumeResponse))
    #expect(!PeerSyncCoordinator.bypassesSerializedMessageProcessing(.fileChunk))
    #expect(!PeerSyncCoordinator.bypassesSerializedMessageProcessing(.syncOperation))
}

@MainActor
struct FileTransferTests {
    @Test func emptyFileTransfer() async throws { try await verifyTransfer(Data(), chunks: []) }
    @Test func smallFileTransfer() async throws { try await verifyTransfer(Data("hello".utf8), chunks: [Data("hello".utf8)]) }

    @Test func multiChunkFileTransfer() async throws {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        let chunks = stride(from: 0, to: data.count, by: 777).map {
            data.subdata(in: $0..<min($0 + 777, data.count))
        }
        try await verifyTransfer(data, chunks: chunks)
    }

    @Test func hashMismatchCleansPartialFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = makePayload(size: 3, hash: "bad", transferID: UUID(), shareID: fixture.shareID)
        try await fixture.receiver.start(payload, rootURL: fixture.root)
        try await fixture.receiver.append(FileChunkPayload(transferID: payload.transferID, index: 0, data: Data("abc".utf8)))
        await #expect(throws: FileTransferReceiver.TransferError.hashMismatch) {
            try await fixture.receiver.complete(transferID: payload.transferID)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("file.bin").path))
    }

    @Test func interruptedTransferCleansPartialFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transferID = UUID()
        let payload = makePayload(size: 3, hash: "unused", transferID: transferID, shareID: fixture.shareID)
        try await fixture.receiver.start(payload, rootURL: fixture.root)
        await fixture.receiver.cancel(transferID: transferID)
        let partial = fixture.root.appendingPathComponent(".peernest/staging/\(transferID.uuidString).partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func destinationIsAtomicallyReplaced() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("file.bin")
        try Data("old".utf8).write(to: destination)
        let newData = Data("new contents".utf8)
        let hash = try await hash(data: newData, in: fixture.root)
        let payload = makePayload(size: Int64(newData.count), hash: hash, transferID: UUID(), shareID: fixture.shareID)
        try await fixture.receiver.start(payload, rootURL: fixture.root)
        try await fixture.receiver.append(FileChunkPayload(transferID: payload.transferID, index: 0, data: newData))
        try await fixture.receiver.complete(transferID: payload.transferID)
        #expect(try Data(contentsOf: destination) == newData)
    }

    private func verifyTransfer(_ data: Data, chunks: [Data]) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hash = try await hash(data: data, in: fixture.root)
        let payload = makePayload(size: Int64(data.count), hash: hash, transferID: UUID(), shareID: fixture.shareID)
        try await fixture.receiver.start(payload, rootURL: fixture.root)
        for (index, chunk) in chunks.enumerated() {
            try await fixture.receiver.append(FileChunkPayload(transferID: payload.transferID, index: index, data: chunk))
        }
        try await fixture.receiver.complete(transferID: payload.transferID)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.bin")) == data)
    }

    private func makeFixture() throws -> (root: URL, shareID: UUID, receiver: FileTransferReceiver) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeerNestTransfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AppliedOperationRegistry()
        return (root, UUID(), FileTransferReceiver(registry: registry))
    }

    private func makePayload(size: Int64, hash: String, transferID: UUID, shareID: UUID) -> FileTransferStartPayload {
        FileTransferStartPayload(
            transferID: transferID,
            operationID: UUID(),
            sourceSharedFolderID: UUID(),
            destinationSharedFolderID: shareID,
            sourceRelativePath: "file.bin",
            destinationRelativePath: "file.bin",
            size: size,
            sha256: hash,
            modificationDate: Date()
        )
    }

    private func hash(data: Data, in directory: URL) async throws -> String {
        let url = directory.appendingPathComponent("hash-source-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await FileHashing.sha256(of: url)
    }
}
