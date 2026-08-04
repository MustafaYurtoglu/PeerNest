//
//  SecureSession.swift
//  PeerNest
//

import CryptoKit
import Foundation

nonisolated enum SecureSessionError: LocalizedError, Equatable, Sendable {
    case wrongSession
    case wrongPeer
    case unsupportedProtocol
    case replayOrOutOfOrder
    case invalidNonce
    case authenticationFailed
    case sequenceExhausted
    case plaintextForbidden

    var errorDescription: String? {
        switch self {
        case .wrongSession: "The encrypted frame belongs to another session."
        case .wrongPeer: "The encrypted frame was signed for another peer."
        case .unsupportedProtocol: "The encrypted frame uses an unsupported protocol version."
        case .replayOrOutOfOrder: "PeerNest rejected a repeated or out-of-order encrypted frame."
        case .invalidNonce: "PeerNest rejected an invalid encryption nonce."
        case .authenticationFailed: "PeerNest could not authenticate an encrypted frame."
        case .sequenceExhausted: "The secure session reached its message limit."
        case .plaintextForbidden: "PeerNest rejected unencrypted normal traffic."
        }
    }
}

nonisolated enum TransportSecurityMode: Equatable, Sendable {
    case authenticated
    case pairing
    #if DEBUG
    case debugPlaintext
    #endif

    var permitsPlaintextNormalMessages: Bool {
        #if DEBUG
        self == .debugPlaintext
        #else
        false
        #endif
    }
}

nonisolated enum SecureSessionKeyDerivation {
    static func deriveKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data,
        transcript: Data
    ) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: transcript)),
            sharedInfo: Data("PeerNest authenticated session v1".utf8),
            outputByteCount: 32
        )
    }

    static func transcript(
        sessionID: UUID,
        firstPeerID: UUID,
        secondPeerID: UUID,
        firstNonce: Data,
        secondNonce: Data
    ) -> Data {
        let ordered: [(UUID, Data)] = [(firstPeerID, firstNonce), (secondPeerID, secondNonce)]
            .sorted { $0.0.uuidString < $1.0.uuidString }
        var data = Data("PeerNest secure session transcript v1".utf8)
        data.append(Data(sessionID.uuidString.utf8))
        for item in ordered {
            data.append(Data(item.0.uuidString.utf8))
            data.append(item.1)
        }
        return data
    }
}

actor AuthenticatedSecureSession {
    let sessionID: UUID
    let localPeerID: UUID
    let remotePeerID: UUID
    let remoteFingerprint: String
    let protocolVersion: Int
    let capabilities: [PeerCapability]
    let establishedAt: Date

    private let key: SymmetricKey
    private var lastActivityAt: Date
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var state: SecureSessionState = .ready

    init(
        sessionID: UUID,
        localPeerID: UUID,
        remotePeerID: UUID,
        remoteFingerprint: String,
        protocolVersion: Int = PeerProtocolConstants.version,
        capabilities: [PeerCapability] = PeerCapability.allCases,
        key: SymmetricKey,
        establishedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.remoteFingerprint = remoteFingerprint
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.key = key
        self.establishedAt = establishedAt
        lastActivityAt = establishedAt
    }

    func seal(messageType: PeerMessageType, plaintext: Data, at date: Date = Date()) throws -> SecureEnvelope {
        guard sendSequence < UInt64.max else { throw SecureSessionError.sequenceExhausted }
        let sequence = sendSequence + 1
        let metadata = SecureEnvelopeMetadata(
            sessionID: sessionID,
            senderPeerID: localPeerID,
            protocolVersion: protocolVersion,
            messageType: messageType,
            sequenceNumber: sequence
        )
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceData(
            sessionID: sessionID,
            senderPeerID: localPeerID,
            remotePeerID: remotePeerID,
            sequence: sequence
        ))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: try PeerMessageCoding.encoder.encode(metadata)
        )
        sendSequence = sequence
        lastActivityAt = date
        return SecureEnvelope(
            sessionID: sessionID,
            senderPeerID: localPeerID,
            protocolVersion: protocolVersion,
            messageType: messageType,
            sequenceNumber: sequence,
            ciphertext: sealed.combined
        )
    }

    func open(_ envelope: SecureEnvelope, at date: Date = Date()) throws -> Data {
        guard envelope.sessionID == sessionID else { throw SecureSessionError.wrongSession }
        guard envelope.senderPeerID == remotePeerID else { throw SecureSessionError.wrongPeer }
        guard envelope.protocolVersion == protocolVersion else { throw SecureSessionError.unsupportedProtocol }
        guard envelope.sequenceNumber == receiveSequence + 1 else { throw SecureSessionError.replayOrOutOfOrder }
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            let expectedNonce = Self.nonceData(
                sessionID: sessionID,
                senderPeerID: remotePeerID,
                remotePeerID: localPeerID,
                sequence: envelope.sequenceNumber
            )
            guard Data(box.nonce) == expectedNonce else { throw SecureSessionError.invalidNonce }
            let metadata = SecureEnvelopeMetadata(
                sessionID: envelope.sessionID,
                senderPeerID: envelope.senderPeerID,
                protocolVersion: envelope.protocolVersion,
                messageType: envelope.messageType,
                sequenceNumber: envelope.sequenceNumber
            )
            let plaintext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: try PeerMessageCoding.encoder.encode(metadata)
            )
            receiveSequence = envelope.sequenceNumber
            lastActivityAt = date
            return plaintext
        } catch let error as SecureSessionError {
            throw error
        } catch {
            throw SecureSessionError.authenticationFailed
        }
    }

    func snapshot() -> SecureSessionSnapshot {
        SecureSessionSnapshot(
            sessionID: sessionID,
            localPeerID: localPeerID,
            remotePeerID: remotePeerID,
            authenticatedRemoteFingerprint: remoteFingerprint,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            establishedAt: establishedAt,
            lastActivityAt: lastActivityAt,
            sendSequenceNumber: sendSequence,
            receiveSequenceNumber: receiveSequence,
            state: state
        )
    }

    func close() { state = .closing }

    static func nonceData(
        sessionID: UUID,
        senderPeerID: UUID,
        remotePeerID: UUID,
        sequence: UInt64
    ) -> Data {
        // The direction marker is deterministic and distinct for both directions. The key itself is
        // unique to `sessionID`, so this gives every frame a unique 96-bit ChaChaPoly nonce.
        let senderOwnsLowerDirection = senderPeerID.uuidString < remotePeerID.uuidString
        var direction = (senderOwnsLowerDirection ? UInt32(1) : UInt32(2)).bigEndian
        var nonce = withUnsafeBytes(of: &direction) { Data($0) }
        var bigEndian = sequence.bigEndian
        nonce.append(withUnsafeBytes(of: &bigEndian) { Data($0) })
        return nonce
    }
}

private nonisolated struct SecureEnvelopeMetadata: Codable, Equatable, Sendable {
    let sessionID: UUID
    let senderPeerID: UUID
    let protocolVersion: Int
    let messageType: PeerMessageType
    let sequenceNumber: UInt64
}
