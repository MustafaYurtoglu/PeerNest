//
//  TrustedPeerStore.swift
//  PeerNest
//

import Foundation

@MainActor
final class TrustedPeerStore {
    enum StoreError: LocalizedError {
        case encodingFailed

        var errorDescription: String? { "PeerNest could not save its trusted-device list." }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var peers: [TrustedPeer]

    init(defaults: UserDefaults = .standard, storageKey: String = "trustedPeers.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? PropertyListDecoder().decode([TrustedPeer].self, from: data) {
            peers = decoded
        } else {
            peers = []
        }
    }

    func peer(id: UUID) -> TrustedPeer? {
        peers.first { $0.peerID == id }
    }

    func save(_ peer: TrustedPeer) throws {
        if let index = peers.firstIndex(where: { $0.peerID == peer.peerID }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        try persist()
    }

    @discardableResult
    func validate(peerID: UUID, publicIdentityKey: Data) throws -> TrustedIdentityValidation {
        guard var known = peer(id: peerID) else { return .unknown }
        guard known.trustState != .revoked else { return .revoked }
        guard known.publicIdentityKey == publicIdentityKey else {
            known.trustState = .identityChanged
            try save(known)
            return .identityChanged
        }
        guard known.trustState == .trusted else { return .identityChanged }
        return .trusted(known)
    }

    func setAutoConnect(_ enabled: Bool, peerID: UUID) throws {
        guard var peer = peer(id: peerID), peer.trustState == .trusted else { return }
        peer.autoConnectEnabled = enabled
        try save(peer)
    }

    func markConnected(peerID: UUID, serviceName: String?, at date: Date = Date()) throws {
        guard var peer = peer(id: peerID), peer.trustState == .trusted else { return }
        peer.lastConnectedAt = date
        peer.lastKnownServiceName = serviceName ?? peer.lastKnownServiceName
        try save(peer)
    }

    /// Keeps a revocation marker and public fingerprint so the identity cannot be silently re-trusted.
    func forget(peerID: UUID, at date: Date = Date()) throws {
        guard var peer = peer(id: peerID) else { return }
        peer.trustState = .revoked
        peer.autoConnectEnabled = false
        peer.revokedAt = date
        try save(peer)
    }

    func explicitlyReplaceIdentity(
        peerID: UUID,
        displayName: String,
        publicIdentityKey: Data,
        serviceName: String?
    ) throws {
        try save(TrustedPeer(
            peerID: peerID,
            displayName: displayName,
            publicIdentityKey: publicIdentityKey,
            fingerprint: PeerFingerprintFormatter.string(for: publicIdentityKey),
            lastKnownServiceName: serviceName
        ))
    }

    private func persist() throws {
        do { defaults.set(try PropertyListEncoder().encode(peers), forKey: storageKey) }
        catch { throw StoreError.encodingFailed }
    }
}

