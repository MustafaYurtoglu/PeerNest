//
//  ShareInvitationPolicy.swift
//  PeerNest
//

import Foundation

nonisolated enum ShareInvitationPolicy {
    static func validateForSending(
        _ invitation: ShareInvitation,
        trustedPeer: TrustedPeer?,
        at date: Date = Date()
    ) throws {
        guard let trustedPeer,
              trustedPeer.peerID == invitation.recipientPeerID,
              trustedPeer.trustState == .trusted else {
            throw PeerNestLANError.authenticationFailed
        }
        guard invitation.state == .pending, !invitation.isExpired(at: date) else {
            throw PeerNestLANError.pairingExpired
        }
    }

    static func validateAcceptance(
        _ invitation: ShareInvitation,
        localDestinationID: UUID?,
        existingMappings: [ShareMapping],
        at date: Date = Date()
    ) throws {
        guard invitation.state == .pending, !invitation.isExpired(at: date) else {
            throw PeerNestLANError.pairingExpired
        }
        guard let localDestinationID else { throw PeerNestLANError.invitationRejected }
        guard !existingMappings.contains(where: {
            $0.remotePeerID == invitation.senderPeerID &&
                ($0.remoteSharedFolderID == invitation.senderSharedFolderID ||
                 $0.localSharedFolderID == localDestinationID)
        }) else { throw ShareMappingStore.StoreError.duplicateMapping }
    }
}
