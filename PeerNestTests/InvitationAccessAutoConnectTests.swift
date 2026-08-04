import Foundation
import Testing
@testable import PeerNest

@MainActor
struct InvitationAccessAutoConnectTests {
    @Test func invitationRequiresTrustAndExplicitUnexpiredAcceptance() throws {
        let sender = UUID()
        let recipient = UUID()
        let folder = UUID()
        let invitation = ShareInvitation(
            senderPeerID: sender,
            recipientPeerID: recipient,
            senderSharedFolderID: folder,
            displayName: "Project",
            accessMode: .readWrite
        )
        #expect(throws: PeerNestLANError.authenticationFailed) {
            try ShareInvitationPolicy.validateForSending(invitation, trustedPeer: nil)
        }
        let trusted = TrustedPeer(
            peerID: recipient,
            displayName: "Mac B",
            publicIdentityKey: Data(repeating: 1, count: 32),
            fingerprint: "fingerprint"
        )
        try ShareInvitationPolicy.validateForSending(invitation, trustedPeer: trusted)
        #expect(throws: PeerNestLANError.invitationRejected) {
            try ShareInvitationPolicy.validateAcceptance(invitation, localDestinationID: nil, existingMappings: [])
        }

        let expired = ShareInvitation(
            senderPeerID: sender,
            recipientPeerID: recipient,
            senderSharedFolderID: folder,
            displayName: "Expired",
            accessMode: .readOnly,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        #expect(throws: PeerNestLANError.pairingExpired) {
            try ShareInvitationPolicy.validateForSending(expired, trustedPeer: trusted, at: Date(timeIntervalSince1970: 2))
        }
    }

    @Test func receiverDestinationAndDuplicateMappingAreEnforced() throws {
        let invitation = ShareInvitation(
            senderPeerID: UUID(),
            recipientPeerID: UUID(),
            senderSharedFolderID: UUID(),
            displayName: "Project",
            accessMode: .readWrite
        )
        let destination = UUID()
        try ShareInvitationPolicy.validateAcceptance(
            invitation,
            localDestinationID: destination,
            existingMappings: []
        )
        let mapping = ShareMapping(
            localSharedFolderID: destination,
            remoteSharedFolderID: invitation.senderSharedFolderID,
            remotePeerID: invitation.senderPeerID,
            localRole: .receiver
        )
        #expect(throws: ShareMappingStore.StoreError.duplicateMapping) {
            try ShareInvitationPolicy.validateAcceptance(
                invitation,
                localDestinationID: destination,
                existingMappings: [mapping]
            )
        }
    }

    @Test func readWriteAndReadOnlyAuthorizationAreEnforced() throws {
        let local = UUID()
        let remote = UUID()
        let readWrite = ShareMapping(
            localSharedFolderID: local,
            remoteSharedFolderID: remote,
            remotePeerID: UUID(),
            accessMode: .readWrite,
            localRole: .receiver
        )
        let outgoing = try SyncOperation(sharedFolderID: local, type: .updateFile, relativePath: "file.txt")
        let incoming = try SyncOperation(sharedFolderID: remote, type: .delete, relativePath: "file.txt")
        try ShareAccessPolicy.authorizeOutgoing(outgoing, mapping: readWrite)
        try ShareAccessPolicy.authorizeIncoming(incoming, destinationSharedFolderID: local, mapping: readWrite)

        let readOnlyReceiver = ShareMapping(
            localSharedFolderID: local,
            remoteSharedFolderID: remote,
            remotePeerID: UUID(),
            accessMode: .readOnly,
            localRole: .receiver
        )
        #expect(throws: PeerNestLANError.unauthorizedOperation) {
            try ShareAccessPolicy.authorizeOutgoing(outgoing, mapping: readOnlyReceiver)
        }
        try ShareAccessPolicy.authorizeIncoming(incoming, destinationSharedFolderID: local, mapping: readOnlyReceiver)

        let readOnlyOwner = ShareMapping(
            localSharedFolderID: local,
            remoteSharedFolderID: remote,
            remotePeerID: UUID(),
            accessMode: .readOnly,
            localRole: .owner
        )
        #expect(throws: PeerNestLANError.unauthorizedOperation) {
            try ShareAccessPolicy.authorizeIncoming(incoming, destinationSharedFolderID: local, mapping: readOnlyOwner)
        }
        try ShareAccessPolicy.authorizeOutgoing(outgoing, mapping: readOnlyOwner)

        var stopped = readWrite
        stopped.isEnabled = false
        #expect(throws: PeerNestLANError.unauthorizedOperation) {
            try ShareAccessPolicy.authorizeIncoming(incoming, destinationSharedFolderID: local, mapping: stopped)
        }
    }

    @Test func autoConnectRequiresTrustedEligibleOwner() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        var peer = TrustedPeer(
            peerID: higher,
            displayName: "Higher Mac",
            publicIdentityKey: Data(repeating: 1, count: 32),
            fingerprint: "fingerprint"
        )
        #expect(AutoConnectPolicy.shouldAutoConnect(
            localPeerID: lower,
            trustedPeer: peer,
            isAvailable: true,
            isManuallyPaused: false
        ))
        #expect(!AutoConnectPolicy.shouldAutoConnect(
            localPeerID: higher,
            trustedPeer: TrustedPeer(
                peerID: lower,
                displayName: "Lower Mac",
                publicIdentityKey: peer.publicIdentityKey,
                fingerprint: peer.fingerprint
            ),
            isAvailable: true,
            isManuallyPaused: false
        ))
        peer.trustState = .revoked
        #expect(!AutoConnectPolicy.shouldAutoConnect(localPeerID: lower, trustedPeer: peer, isAvailable: true, isManuallyPaused: false))
        peer.trustState = .identityChanged
        #expect(!AutoConnectPolicy.shouldAutoConnect(localPeerID: lower, trustedPeer: peer, isAvailable: true, isManuallyPaused: false))
    }
}
