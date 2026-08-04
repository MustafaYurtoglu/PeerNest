//
//  PairingSession.swift
//  PeerNest
//

import CryptoKit
import Foundation

nonisolated enum PairingSessionError: LocalizedError, Equatable, Sendable {
    case invalidState
    case sessionMismatch
    case peerMismatch
    case protocolMismatch
    case expired
    case replayedMessage
    case invalidConfirmation
    case rejected

    var errorDescription: String? {
        switch self {
        case .invalidState: "The pairing session is not ready for that action."
        case .sessionMismatch: "The pairing response belongs to another session."
        case .peerMismatch: "The pairing identity was inconsistent."
        case .protocolMismatch: "The other device uses an incompatible pairing protocol."
        case .expired: "The pairing request expired."
        case .replayedMessage: "PeerNest rejected a repeated pairing message."
        case .invalidConfirmation: "The other device’s pairing confirmation could not be verified."
        case .rejected: "The other device rejected pairing."
        }
    }
}

nonisolated enum PairingCrypto {
    static func verificationCode(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data,
        transcript: PairingTranscript
    ) throws -> String {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
        let transcriptData = try transcript.canonicalData()
        let digest = Data(SHA256.hash(data: transcriptData))
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: digest,
            sharedInfo: Data("PeerNest pairing verification v1".utf8),
            outputByteCount: 32
        )
        let bytes = key.withUnsafeBytes { Array($0.prefix(8)) }
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000
        return String(format: "%06llu", value)
    }

    static func transcriptDigest(_ transcript: PairingTranscript) throws -> Data {
        Data(SHA256.hash(data: try transcript.canonicalData()))
    }
}

actor PairingSession {
    let sessionID: UUID
    let role: PairingRole
    let localPeerID: UUID
    private(set) var remotePeerID: UUID?
    private(set) var state: PairingState

    private let localDisplayName: String
    private let localIdentity: DeviceCryptographicIdentity
    private let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let createdAt: Date
    private let expiresAt: Date
    private var localHello: PairingHello
    private var remoteHello: PairingHello?
    private var transcript: PairingTranscript?
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var seenMessageIDs: Set<UUID> = []

    init(
        localPeerID: UUID,
        localDisplayName: String,
        remotePeerID: UUID? = nil,
        role: PairingRole,
        identity: DeviceCryptographicIdentity,
        sessionID: UUID = UUID(),
        now: Date = Date(),
        lifetime: TimeInterval = 120,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) {
        self.sessionID = sessionID
        self.role = role
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.localDisplayName = localDisplayName
        localIdentity = identity
        self.ephemeralPrivateKey = ephemeralPrivateKey
        createdAt = now
        expiresAt = now.addingTimeInterval(lifetime)
        state = role == .initiator ? .requesting : .awaitingRemoteApproval
        localHello = PairingHello(
            messageID: UUID(),
            sessionID: sessionID,
            role: role,
            peerID: localPeerID,
            displayName: localDisplayName,
            protocolVersion: PeerProtocolConstants.version,
            publicIdentityKey: identity.publicIdentityKey,
            ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            nonce: Self.randomNonce(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    func hello(at now: Date = Date()) throws -> PairingHello {
        try checkExpiration(now)
        return localHello
    }

    @discardableResult
    func receive(_ hello: PairingHello, at now: Date = Date()) throws -> String {
        try checkExpiration(now)
        try register(messageID: hello.messageID)
        guard hello.sessionID == sessionID else { throw PairingSessionError.sessionMismatch }
        if let remotePeerID, hello.peerID != remotePeerID { throw PairingSessionError.peerMismatch }
        guard hello.peerID != localPeerID else { throw PairingSessionError.peerMismatch }
        remotePeerID = hello.peerID
        guard hello.role != role else { throw PairingSessionError.invalidState }
        guard hello.protocolVersion == PeerProtocolConstants.version else { throw PairingSessionError.protocolMismatch }
        guard now < hello.expiresAt else { throw PairingSessionError.expired }

        remoteHello = hello
        let transcript = role == .initiator
            ? PairingTranscript(initiator: localHello, responder: hello)
            : PairingTranscript(initiator: hello, responder: localHello)
        self.transcript = transcript
        let code = try PairingCrypto.verificationCode(
            privateKey: ephemeralPrivateKey,
            remotePublicKey: hello.ephemeralPublicKey,
            transcript: transcript
        )
        state = .awaitingCodeConfirmation(code: code, expiresAt: min(expiresAt, hello.expiresAt))
        return code
    }

    func confirmCodesMatch(at now: Date = Date()) throws -> PairingConfirmation {
        try checkExpiration(now)
        guard let transcript, remoteHello != nil else { throw PairingSessionError.invalidState }
        let digest = try PairingCrypto.transcriptDigest(transcript)
        localConfirmed = true
        state = remoteConfirmed ? .paired : .confirming
        return PairingConfirmation(
            messageID: UUID(),
            sessionID: sessionID,
            peerID: localPeerID,
            transcriptDigest: digest,
            signature: try localIdentity.signature(for: confirmationMaterial(digest: digest, peerID: localPeerID)),
            confirmedAt: now
        )
    }

    func receive(_ confirmation: PairingConfirmation, at now: Date = Date()) throws {
        try checkExpiration(now)
        try register(messageID: confirmation.messageID)
        guard confirmation.sessionID == sessionID, confirmation.peerID == remotePeerID,
              let transcript, let remoteHello else { throw PairingSessionError.invalidConfirmation }
        let expectedDigest = try PairingCrypto.transcriptDigest(transcript)
        guard confirmation.transcriptDigest == expectedDigest,
              let remoteSigningKey = try? Curve25519.Signing.PublicKey(rawRepresentation: remoteHello.publicIdentityKey),
              remoteSigningKey.isValidSignature(
                confirmation.signature,
                for: confirmationMaterial(digest: expectedDigest, peerID: confirmation.peerID)
              ) else { throw PairingSessionError.invalidConfirmation }
        remoteConfirmed = true
        state = localConfirmed ? .paired : .awaitingCodeConfirmation(
            code: try PairingCrypto.verificationCode(
                privateKey: ephemeralPrivateKey,
                remotePublicKey: remoteHello.ephemeralPublicKey,
                transcript: transcript
            ),
            expiresAt: min(expiresAt, remoteHello.expiresAt)
        )
    }

    func reject() {
        state = .rejected
    }

    func completedTrustedPeer(serviceName: String? = nil) throws -> TrustedPeer {
        guard localConfirmed, remoteConfirmed, let remoteHello else { throw PairingSessionError.invalidState }
        return TrustedPeer(
            peerID: remoteHello.peerID,
            displayName: remoteHello.displayName,
            publicIdentityKey: remoteHello.publicIdentityKey,
            fingerprint: PeerFingerprintFormatter.string(for: remoteHello.publicIdentityKey),
            lastKnownServiceName: serviceName
        )
    }

    static func preferredRole(localPeerID: UUID, remotePeerID: UUID) -> PairingRole {
        localPeerID.uuidString < remotePeerID.uuidString ? .initiator : .responder
    }

    private func checkExpiration(_ now: Date) throws {
        guard now < expiresAt else {
            state = .expired
            throw PairingSessionError.expired
        }
    }

    private func register(messageID: UUID) throws {
        guard seenMessageIDs.insert(messageID).inserted else { throw PairingSessionError.replayedMessage }
    }

    private func confirmationMaterial(digest: Data, peerID: UUID) -> Data {
        var data = Data("PeerNest pairing confirmation v1".utf8)
        data.append(digest)
        data.append(Data(peerID.uuidString.utf8))
        return data
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
