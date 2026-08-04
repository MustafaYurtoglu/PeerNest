import CryptoKit
import Foundation
import Testing
@testable import PeerNest

@MainActor
struct PairingSecurityTests {
    @Test func simultaneousPairingRoleIsDeterministic() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        #expect(PairingSession.preferredRole(localPeerID: lower, remotePeerID: higher) == .initiator)
        #expect(PairingSession.preferredRole(localPeerID: higher, remotePeerID: lower) == .responder)
    }

    @Test func bothSidesDeriveSameCodeAndModifiedTranscriptDiffers() async throws {
        let pair = try await makeSessions()
        let helloA = try await pair.a.hello(at: pair.now)
        let helloB = try await pair.b.hello(at: pair.now)
        let codeA = try await pair.a.receive(helloB, at: pair.now)
        let codeB = try await pair.b.receive(helloA, at: pair.now)
        #expect(codeA == codeB)
        #expect(codeA.count == 6)

        let modified = PairingHello(
            messageID: helloB.messageID,
            sessionID: helloB.sessionID,
            role: helloB.role,
            peerID: helloB.peerID,
            displayName: "Modified Name",
            protocolVersion: helloB.protocolVersion,
            publicIdentityKey: helloB.publicIdentityKey,
            ephemeralPublicKey: helloB.ephemeralPublicKey,
            nonce: helloB.nonce,
            createdAt: helloB.createdAt,
            expiresAt: helloB.expiresAt
        )
        let transcript = PairingTranscript(initiator: helloA, responder: modified)
        let changedCode = try PairingCrypto.verificationCode(
            privateKey: pair.aKey,
            remotePublicKey: helloB.ephemeralPublicKey,
            transcript: transcript
        )
        #expect(changedCode != codeA)
    }

    @Test func replayedMessageAndExpiredSessionAreRejected() async throws {
        let pair = try await makeSessions()
        let helloA = try await pair.a.hello(at: pair.now)
        _ = try await pair.b.receive(helloA, at: pair.now)
        await #expect(throws: PairingSessionError.replayedMessage) {
            try await pair.b.receive(helloA, at: pair.now)
        }

        let expired = PairingSession(
            localPeerID: UUID(),
            localDisplayName: "Expired",
            role: .initiator,
            identity: pair.identityA,
            now: pair.now,
            lifetime: 1
        )
        await #expect(throws: PairingSessionError.expired) {
            try await expired.hello(at: pair.now.addingTimeInterval(2))
        }
    }

    @Test func bothSignedConfirmationsAreRequiredAndSuccessProducesTrust() async throws {
        let pair = try await makeSessions()
        let helloA = try await pair.a.hello(at: pair.now)
        let helloB = try await pair.b.hello(at: pair.now)
        _ = try await pair.a.receive(helloB, at: pair.now)
        _ = try await pair.b.receive(helloA, at: pair.now)
        let confirmationA = try await pair.a.confirmCodesMatch(at: pair.now)
        await #expect(throws: PairingSessionError.invalidState) {
            try await pair.a.completedTrustedPeer()
        }
        let confirmationB = try await pair.b.confirmCodesMatch(at: pair.now)
        try await pair.a.receive(confirmationB, at: pair.now)
        try await pair.b.receive(confirmationA, at: pair.now)
        let trustedByA = try await pair.a.completedTrustedPeer()
        let trustedByB = try await pair.b.completedTrustedPeer()
        #expect(trustedByA.peerID == pair.peerB)
        #expect(trustedByB.peerID == pair.peerA)
    }

    @Test func rejectionCreatesNoTrust() async throws {
        let pair = try await makeSessions()
        await pair.a.reject()
        await #expect(throws: PairingSessionError.invalidState) {
            try await pair.a.completedTrustedPeer()
        }
    }

    private func makeSessions() async throws -> (
        a: PairingSession,
        b: PairingSession,
        identityA: DeviceCryptographicIdentity,
        aKey: Curve25519.KeyAgreement.PrivateKey,
        peerA: UUID,
        peerB: UUID,
        now: Date
    ) {
        let identityA = try await DeviceIdentityStore(keyStore: InMemorySecureKeyStore()).identity()
        let identityB = try await DeviceIdentityStore(keyStore: InMemorySecureKeyStore()).identity()
        let peerA = UUID()
        let peerB = UUID()
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keyA = Curve25519.KeyAgreement.PrivateKey()
        let keyB = Curve25519.KeyAgreement.PrivateKey()
        let a = PairingSession(
            localPeerID: peerA,
            localDisplayName: "Mac A",
            remotePeerID: peerB,
            role: .initiator,
            identity: identityA,
            sessionID: sessionID,
            now: now,
            ephemeralPrivateKey: keyA
        )
        let b = PairingSession(
            localPeerID: peerB,
            localDisplayName: "Mac B",
            remotePeerID: peerA,
            role: .responder,
            identity: identityB,
            sessionID: sessionID,
            now: now,
            ephemeralPrivateKey: keyB
        )
        // The test also independently exercises transcript derivation with a known ephemeral key.
        return (a, b, identityA, keyA, peerA, peerB, now)
    }
}
