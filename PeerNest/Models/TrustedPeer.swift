//
//  TrustedPeer.swift
//  PeerNest
//

import Foundation

nonisolated enum PeerTrustState: String, Codable, Sendable {
    case unpaired
    case pairingPending
    case trusted
    case revoked
    case identityChanged
}

nonisolated struct TrustedPeer: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { peerID }

    let peerID: UUID
    var displayName: String
    var publicIdentityKey: Data
    var fingerprint: String
    var pairedAt: Date
    var lastConnectedAt: Date?
    var lastKnownServiceName: String?
    var trustState: PeerTrustState
    var autoConnectEnabled: Bool
    var revokedAt: Date?

    init(
        peerID: UUID,
        displayName: String,
        publicIdentityKey: Data,
        fingerprint: String,
        pairedAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        lastKnownServiceName: String? = nil,
        trustState: PeerTrustState = .trusted,
        autoConnectEnabled: Bool = true,
        revokedAt: Date? = nil
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.publicIdentityKey = publicIdentityKey
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
        self.lastKnownServiceName = lastKnownServiceName
        self.trustState = trustState
        self.autoConnectEnabled = autoConnectEnabled
        self.revokedAt = revokedAt
    }
}

nonisolated enum TrustedIdentityValidation: Equatable, Sendable {
    case trusted(TrustedPeer)
    case unknown
    case revoked
    case identityChanged
}

