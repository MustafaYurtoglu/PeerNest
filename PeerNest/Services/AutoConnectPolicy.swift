//
//  AutoConnectPolicy.swift
//  PeerNest
//

import Foundation

nonisolated enum AutoConnectPolicy {
    static func shouldAutoConnect(
        localPeerID: UUID,
        trustedPeer: TrustedPeer,
        isAvailable: Bool,
        isManuallyPaused: Bool
    ) -> Bool {
        isAvailable && !isManuallyPaused && trustedPeer.autoConnectEnabled &&
            trustedPeer.trustState == .trusted && ownsPrimaryConnection(
                localPeerID: localPeerID,
                remotePeerID: trustedPeer.peerID
            )
    }

    /// The lexicographically lower stable peer ID owns the outbound primary connection.
    static func ownsPrimaryConnection(localPeerID: UUID, remotePeerID: UUID) -> Bool {
        localPeerID.uuidString < remotePeerID.uuidString
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        let bounded = max(0, min(attempt, 6))
        return min(pow(2, Double(bounded)), 32)
    }
}
