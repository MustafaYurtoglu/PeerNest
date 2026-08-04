//
//  SecureSessionModels.swift
//  PeerNest
//

import Foundation

nonisolated enum SecureSessionState: String, Codable, Sendable {
    case connecting
    case pairing
    case authenticating
    case ready
    case closing
    case failed
}

nonisolated struct SecureSessionHello: Codable, Equatable, Sendable {
    let messageID: UUID
    let sessionID: UUID
    let peerID: UUID
    let protocolVersion: Int
    let capabilities: [PeerCapability]
    let publicIdentityKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let createdAt: Date
    let signature: Data

    func signingMaterial() throws -> Data {
        try PeerMessageCoding.encoder.encode(UnsignedSecureSessionHello(
            messageID: messageID,
            sessionID: sessionID,
            peerID: peerID,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            publicIdentityKey: publicIdentityKey,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            createdAt: createdAt
        ))
    }
}

nonisolated struct UnsignedSecureSessionHello: Codable, Equatable, Sendable {
    let messageID: UUID
    let sessionID: UUID
    let peerID: UUID
    let protocolVersion: Int
    let capabilities: [PeerCapability]
    let publicIdentityKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let createdAt: Date
}

nonisolated struct SecureEnvelope: Codable, Equatable, Sendable {
    let sessionID: UUID
    let senderPeerID: UUID
    let protocolVersion: Int
    let messageType: PeerMessageType
    let sequenceNumber: UInt64
    let ciphertext: Data
}

nonisolated struct SecureSessionSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let localPeerID: UUID
    let remotePeerID: UUID
    let authenticatedRemoteFingerprint: String
    let protocolVersion: Int
    let capabilities: [PeerCapability]
    let establishedAt: Date
    let lastActivityAt: Date
    let sendSequenceNumber: UInt64
    let receiveSequenceNumber: UInt64
    let state: SecureSessionState
}
