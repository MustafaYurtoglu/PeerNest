//
//  PeerProtocol.swift
//  PeerNest
//

import Foundation

nonisolated enum PeerProtocolConstants {
    static let version = 1
    static let maximumMessageSize = 8 * 1024 * 1024
    static let defaultFileChunkSize = 256 * 1024
}

nonisolated enum PeerMessageType: String, Codable, Sendable {
    case hello
    case helloAck
    case pairingHello
    case pairingConfirmation
    case pairingRejection
    case secureSessionHello
    case encrypted
    case shareInvitation
    case shareInvitationResponse
    case shareOffer
    case shareAccept
    case manifestRequest
    case manifestResponse
    case syncOperation
    case fileTransferStart
    case fileChunk
    case fileTransferComplete
    case fileTransferResumeRequest
    case fileTransferResumeResponse
    case operationAck
    case reconciliationSummary
    case reconciliationOperations
    case reconciliationComplete
    case tombstone
    case conflictResolution
    case error
    case ping
    case pong
}

nonisolated struct PeerMessage: Codable, Identifiable, Sendable {
    let protocolVersion: Int
    let messageID: UUID
    let senderPeerID: UUID
    let sentAt: Date
    let messageType: PeerMessageType
    let payload: Data

    var id: UUID { messageID }

    init<Payload: Encodable>(
        senderPeerID: UUID,
        messageType: PeerMessageType,
        payload: Payload,
        messageID: UUID = UUID(),
        sentAt: Date = Date(),
        protocolVersion: Int = PeerProtocolConstants.version
    ) throws {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.senderPeerID = senderPeerID
        self.sentAt = sentAt
        self.messageType = messageType
        self.payload = try PeerMessageCoding.encoder.encode(payload)
    }

    func decodePayload<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        try PeerMessageCoding.decoder.decode(type, from: payload)
    }
}

nonisolated enum PeerMessageCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

nonisolated enum PeerCapability: String, Codable, CaseIterable, Sendable {
    case bidirectionalSync
    case recursiveFolders
    case chunkedTransfer
    case deleteOperations
    case conflictCopies
    case persistentJournal
    case reconciliation
    case tombstones
    case resumableTransfer
}

nonisolated struct HelloPayload: Codable, Sendable {
    let peerID: UUID
    let displayName: String
    let protocolVersion: Int
    let appVersion: String
    let capabilities: [PeerCapability]
}

nonisolated struct HelloAckPayload: Codable, Sendable {
    let acknowledgedPeerID: UUID
    let peerID: UUID
    let displayName: String
    let protocolVersion: Int
    let capabilities: [PeerCapability]
}

nonisolated struct EmptyPayload: Codable, Sendable {}
nonisolated struct PingPayload: Codable, Sendable { let nonce: UUID }
nonisolated struct PongPayload: Codable, Sendable { let nonce: UUID }
nonisolated struct PeerErrorPayload: Codable, Sendable { let code: String; let message: String }

nonisolated struct ShareOfferPayload: Codable, Sendable {
    let sharedFolderID: UUID
    let displayName: String
    let accessMode: SharedFolderAccessMode
}

nonisolated struct ShareAcceptPayload: Codable, Sendable {
    let offeredSharedFolderID: UUID
    let acceptingSharedFolderID: UUID
    let accessMode: SharedFolderAccessMode
}

nonisolated struct ManifestRequestPayload: Codable, Sendable {
    let requesterSharedFolderID: UUID
    let requestedSharedFolderID: UUID
    let requesterEntries: [SyncManifestEntry]
}

nonisolated struct ManifestResponsePayload: Codable, Sendable {
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let entries: [SyncManifestEntry]
}

nonisolated struct NetworkSyncOperationPayload: Codable, Sendable {
    let operation: SyncOperation
    let destinationSharedFolderID: UUID
    let mappingID: UUID?
    let sourceVersion: FileVersion?
    let expectedDestinationVersionID: UUID?
    let logicalSequence: UInt64?

    init(
        operation: SyncOperation,
        destinationSharedFolderID: UUID,
        mappingID: UUID? = nil,
        sourceVersion: FileVersion? = nil,
        expectedDestinationVersionID: UUID? = nil,
        logicalSequence: UInt64? = nil
    ) {
        self.operation = operation
        self.destinationSharedFolderID = destinationSharedFolderID
        self.mappingID = mappingID
        self.sourceVersion = sourceVersion
        self.expectedDestinationVersionID = expectedDestinationVersionID
        self.logicalSequence = logicalSequence
    }
}

nonisolated struct FileTransferStartPayload: Codable, Sendable {
    let transferID: UUID
    let operationID: UUID
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let sourceRelativePath: String
    let destinationRelativePath: String
    let size: Int64
    let sha256: String
    let modificationDate: Date
    let mappingID: UUID?
    let chunkSize: Int?
    let resumeToken: String?

    init(
        transferID: UUID,
        operationID: UUID,
        sourceSharedFolderID: UUID,
        destinationSharedFolderID: UUID,
        sourceRelativePath: String,
        destinationRelativePath: String,
        size: Int64,
        sha256: String,
        modificationDate: Date,
        mappingID: UUID? = nil,
        chunkSize: Int? = nil,
        resumeToken: String? = nil
    ) {
        self.transferID = transferID
        self.operationID = operationID
        self.sourceSharedFolderID = sourceSharedFolderID
        self.destinationSharedFolderID = destinationSharedFolderID
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.size = size
        self.sha256 = sha256
        self.modificationDate = modificationDate
        self.mappingID = mappingID
        self.chunkSize = chunkSize
        self.resumeToken = resumeToken
    }
}

nonisolated struct FileChunkPayload: Codable, Sendable {
    let transferID: UUID
    let index: Int
    let data: Data
    let offset: Int64?

    init(transferID: UUID, index: Int, data: Data, offset: Int64? = nil) {
        self.transferID = transferID
        self.index = index
        self.data = data
        self.offset = offset
    }
}

nonisolated struct FileTransferCompletePayload: Codable, Sendable { let transferID: UUID }

nonisolated struct FileTransferResumeRequestPayload: Codable, Sendable {
    let transferID: UUID
    let operationID: UUID
    let expectedHash: String
    let sourceModificationDate: Date
}

nonisolated struct FileTransferResumeResponsePayload: Codable, Sendable {
    let transferID: UUID
    let accepted: Bool
    let nextExpectedOffset: Int64
    let nextChunkIndex: Int
}

nonisolated struct ReconciliationOperationSummary: Codable, Sendable {
    let operationID: UUID
    let logicalSequence: UInt64
    let state: JournalOperationState
    let relativePathHash: String
}

nonisolated struct ReconciliationSummaryPayload: Codable, Sendable {
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let mappingID: UUID
    let logicalClock: UInt64
    let checkpoint: MappingCheckpoint
    let operations: [ReconciliationOperationSummary]
    let tombstones: [Tombstone]
    let hasMoreOperations: Bool
}

nonisolated struct ReconciliationOperationsPayload: Codable, Sendable {
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let mappingID: UUID
    let operations: [NetworkSyncOperationPayload]
}

nonisolated struct ReconciliationCompletePayload: Codable, Sendable {
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let mappingID: UUID
    let highestAppliedSequence: UInt64
}

nonisolated struct TombstonePayload: Codable, Sendable {
    let sourceSharedFolderID: UUID
    let destinationSharedFolderID: UUID
    let tombstone: Tombstone
}

nonisolated struct ConflictResolutionPayload: Codable, Sendable {
    let conflictID: UUID
    let mappingID: UUID
    let resolution: ConflictResolutionState
    let generatedCopyPaths: [String]
}

nonisolated enum OperationAcknowledgmentState: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

nonisolated struct OperationAckPayload: Codable, Sendable {
    let operationID: UUID
    let state: OperationAcknowledgmentState
    let message: String?
}

nonisolated enum PeerFrameError: LocalizedError, Equatable {
    case oversizedFrame(Int)
    case malformedPayload
    case unsupportedProtocolVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .oversizedFrame(size): "The peer sent an oversized message (\(size) bytes)."
        case .malformedPayload: "The peer sent a malformed message."
        case let .unsupportedProtocolVersion(version): "Peer protocol version \(version) is unsupported."
        }
    }
}

nonisolated struct PeerFrameCodec {
    static func encode(_ message: PeerMessage, maximumMessageSize: Int = PeerProtocolConstants.maximumMessageSize) throws -> Data {
        let payload = try PeerMessageCoding.encoder.encode(message)
        guard payload.count <= maximumMessageSize else { throw PeerFrameError.oversizedFrame(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

actor PeerFrameDecoder {
    private var buffer = Data()
    private let maximumMessageSize: Int

    init(maximumMessageSize: Int = PeerProtocolConstants.maximumMessageSize) {
        self.maximumMessageSize = maximumMessageSize
    }

    func append(_ data: Data) throws -> [PeerMessage] {
        buffer.append(data)
        var messages: [PeerMessage] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payloadLength = Int(length)
            guard payloadLength <= maximumMessageSize else {
                buffer.removeAll()
                throw PeerFrameError.oversizedFrame(payloadLength)
            }
            guard buffer.count >= 4 + payloadLength else { break }
            let payload = buffer.subdata(in: 4..<(4 + payloadLength))
            buffer.removeSubrange(0..<(4 + payloadLength))
            guard let message = try? PeerMessageCoding.decoder.decode(PeerMessage.self, from: payload) else {
                throw PeerFrameError.malformedPayload
            }
            guard message.protocolVersion == PeerProtocolConstants.version else {
                throw PeerFrameError.unsupportedProtocolVersion(message.protocolVersion)
            }
            messages.append(message)
        }
        return messages
    }
}
