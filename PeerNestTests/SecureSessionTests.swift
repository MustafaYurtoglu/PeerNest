import CryptoKit
import Foundation
import Testing
@testable import PeerNest

@MainActor
struct SecureSessionTests {
    @Test func bothSidesDeriveCompatibleSessionKeys() throws {
        let material = makeKeyMaterial()
        let keyA = try SecureSessionKeyDerivation.deriveKey(
            privateKey: material.privateA,
            remotePublicKey: material.privateB.publicKey.rawRepresentation,
            transcript: material.transcript
        )
        let keyB = try SecureSessionKeyDerivation.deriveKey(
            privateKey: material.privateB,
            remotePublicKey: material.privateA.publicKey.rawRepresentation,
            transcript: material.transcript
        )
        #expect(bytes(keyA) == bytes(keyB))
    }

    @Test func ciphertextDecryptsAndNoncesAreUnique() async throws {
        let pair = try makeSessionPair()
        let first = try await pair.a.seal(messageType: .ping, plaintext: Data("first".utf8))
        let second = try await pair.a.seal(messageType: .ping, plaintext: Data("second".utf8))
        #expect(first.ciphertext.prefix(12) != second.ciphertext.prefix(12))
        #expect(try await pair.b.open(first) == Data("first".utf8))
        #expect(try await pair.b.open(second) == Data("second".utf8))

        let reverse = try await pair.b.seal(messageType: .pong, plaintext: Data("reverse".utf8))
        #expect(first.ciphertext.prefix(12) != reverse.ciphertext.prefix(12))
        #expect(try await pair.a.open(reverse) == Data("reverse".utf8))
    }

    @Test func tamperingWrongIdentityAndReplayAreRejected() async throws {
        let tamperPair = try makeSessionPair()
        let original = try await tamperPair.a.seal(messageType: .ping, plaintext: Data("secret".utf8))
        var bytes = original.ciphertext
        bytes[bytes.index(before: bytes.endIndex)] ^= 0x01
        let tampered = SecureEnvelope(
            sessionID: original.sessionID,
            senderPeerID: original.senderPeerID,
            protocolVersion: original.protocolVersion,
            messageType: original.messageType,
            sequenceNumber: original.sequenceNumber,
            ciphertext: bytes
        )
        await #expect(throws: SecureSessionError.authenticationFailed) {
            try await tamperPair.b.open(tampered)
        }

        let wrongPair = try makeSessionPair()
        let valid = try await wrongPair.a.seal(messageType: .ping, plaintext: Data())
        let wrongSender = SecureEnvelope(
            sessionID: valid.sessionID,
            senderPeerID: UUID(),
            protocolVersion: valid.protocolVersion,
            messageType: valid.messageType,
            sequenceNumber: valid.sequenceNumber,
            ciphertext: valid.ciphertext
        )
        await #expect(throws: SecureSessionError.wrongPeer) {
            try await wrongPair.b.open(wrongSender)
        }

        let replayPair = try makeSessionPair()
        let frame = try await replayPair.a.seal(messageType: .ping, plaintext: Data())
        _ = try await replayPair.b.open(frame)
        await #expect(throws: SecureSessionError.replayOrOutOfOrder) {
            try await replayPair.b.open(frame)
        }
    }

    @Test func productionModeRejectsPlaintext() {
        #expect(!TransportSecurityMode.authenticated.permitsPlaintextNormalMessages)
        #if DEBUG
        #expect(TransportSecurityMode.debugPlaintext.permitsPlaintextNormalMessages)
        #endif
    }

    private func makeSessionPair() throws -> (a: AuthenticatedSecureSession, b: AuthenticatedSecureSession) {
        let material = makeKeyMaterial()
        let keyA = try SecureSessionKeyDerivation.deriveKey(
            privateKey: material.privateA,
            remotePublicKey: material.privateB.publicKey.rawRepresentation,
            transcript: material.transcript
        )
        let keyB = try SecureSessionKeyDerivation.deriveKey(
            privateKey: material.privateB,
            remotePublicKey: material.privateA.publicKey.rawRepresentation,
            transcript: material.transcript
        )
        return (
            AuthenticatedSecureSession(
                sessionID: material.sessionID,
                localPeerID: material.peerA,
                remotePeerID: material.peerB,
                remoteFingerprint: "B",
                key: keyA
            ),
            AuthenticatedSecureSession(
                sessionID: material.sessionID,
                localPeerID: material.peerB,
                remotePeerID: material.peerA,
                remoteFingerprint: "A",
                key: keyB
            )
        )
    }

    private func makeKeyMaterial() -> (
        privateA: Curve25519.KeyAgreement.PrivateKey,
        privateB: Curve25519.KeyAgreement.PrivateKey,
        peerA: UUID,
        peerB: UUID,
        sessionID: UUID,
        transcript: Data
    ) {
        let privateA = Curve25519.KeyAgreement.PrivateKey()
        let privateB = Curve25519.KeyAgreement.PrivateKey()
        let peerA = UUID()
        let peerB = UUID()
        let sessionID = UUID()
        let transcript = SecureSessionKeyDerivation.transcript(
            sessionID: sessionID,
            firstPeerID: peerA,
            secondPeerID: peerB,
            firstNonce: Data(repeating: 1, count: 32),
            secondNonce: Data(repeating: 2, count: 32)
        )
        return (privateA, privateB, peerA, peerB, sessionID, transcript)
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

