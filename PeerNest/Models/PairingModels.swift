//
//  PairingModels.swift
//  PeerNest
//

import Foundation

nonisolated enum PairingState: Equatable, Sendable {
    case idle
    case requesting
    case awaitingRemoteApproval
    case awaitingCodeConfirmation(code: String, expiresAt: Date)
    case confirming
    case paired
    case rejected
    case expired
    case failed(String)
}

nonisolated enum PairingRole: String, Codable, Sendable {
    case initiator
    case responder
}

nonisolated struct PairingHello: Codable, Equatable, Sendable {
    let messageID: UUID
    let sessionID: UUID
    let role: PairingRole
    let peerID: UUID
    let displayName: String
    let protocolVersion: Int
    let publicIdentityKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let createdAt: Date
    let expiresAt: Date
}

nonisolated struct PairingTranscript: Codable, Equatable, Sendable {
    let initiator: PairingHello
    let responder: PairingHello

    func canonicalData() throws -> Data {
        try PeerMessageCoding.encoder.encode(self)
    }
}

nonisolated struct PairingConfirmation: Codable, Equatable, Sendable {
    let messageID: UUID
    let sessionID: UUID
    let peerID: UUID
    let transcriptDigest: Data
    let signature: Data
    let confirmedAt: Date
}

nonisolated struct PairingRejection: Codable, Equatable, Sendable {
    let messageID: UUID
    let sessionID: UUID
    let peerID: UUID
}

nonisolated enum PairingWireMessage: Codable, Equatable, Sendable {
    case hello(PairingHello)
    case confirmation(PairingConfirmation)
    case rejection(PairingRejection)
}

nonisolated struct PairingActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

