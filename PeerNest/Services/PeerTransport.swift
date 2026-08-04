//
//  PeerTransport.swift
//  PeerNest
//

import CryptoKit
import Foundation
import Network

enum PeerHandshakeState: Equatable, Sendable {
    case idle
    case exchangingHello
    case authenticating
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Not started"
        case .exchangingHello: "Exchanging hello"
        case .authenticating: "Authenticating encrypted session"
        case .ready: "Ready"
        case let .failed(message): "Failed: \(message)"
        }
    }
}

@MainActor
final class PeerTransport {
    var onConnectionStateChanged: ((PeerConnectionState) -> Void)?
    var onListeningStateChanged: ((PeerConnectionState) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onHandshakeStateChanged: ((PeerHandshakeState) -> Void)?
    var onRemotePeerChanged: ((HelloPayload?) -> Void)?
    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onPairingConnectionReady: (() -> Void)?
    var onPairingMessage: ((PairingWireMessage) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var connectionState: PeerConnectionState = .setup
    private(set) var handshakeState: PeerHandshakeState = .idle
    private(set) var remotePeer: HelloPayload?
    private(set) var secureSessionSnapshot: SecureSessionSnapshot?

    private enum ConnectionMode {
        case undecided
        case pairing
        case authenticated
        #if DEBUG
        case debugPlaintext
        #endif
    }

    private enum OutboundTarget {
        case host(String, UInt16)
        case endpoint(NWEndpoint)
    }

    private let identity: PeerIdentity
    private let configuredSecurityMode: TransportSecurityMode
    private let cryptographicIdentity: DeviceCryptographicIdentity?
    private let trustedPeerProvider: (UUID) -> TrustedPeer?
    private let identityChangedHandler: (UUID, Data) -> Void
    private let server = PeerServer()
    private var connection: PeerConnection?
    private var outboundTarget: OutboundTarget?
    private var expectedTrustedPeer: TrustedPeer?
    private var connectionMode: ConnectionMode = .undecided
    private var isOutgoing = false
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var messageProcessingTask: Task<Void, Never>?
    private var receivedHello = false
    private var receivedHelloAck = false
    private var manualDisconnect = false
    private var reconnectAttempt = 0
    private var lastReceivedAt = Date()
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var localSecureHello: SecureSessionHello?
    private var remoteSecureHello: SecureSessionHello?
    private var secureSession: AuthenticatedSecureSession?
    private var authenticationFailureCount = 0

    #if DEBUG
    convenience init(identity: PeerIdentity) {
        self.init(identity: identity, securityMode: .debugPlaintext)
    }
    #else
    convenience init(identity: PeerIdentity) {
        self.init(identity: identity, securityMode: .authenticated)
    }
    #endif

    init(
        identity: PeerIdentity,
        securityMode: TransportSecurityMode,
        cryptographicIdentity: DeviceCryptographicIdentity? = nil,
        trustedPeerProvider: @escaping (UUID) -> TrustedPeer? = { _ in nil },
        identityChangedHandler: @escaping (UUID, Data) -> Void = { _, _ in }
    ) {
        self.identity = identity
        configuredSecurityMode = securityMode
        self.cryptographicIdentity = cryptographicIdentity
        self.trustedPeerProvider = trustedPeerProvider
        self.identityChangedHandler = identityChangedHandler
        server.onConnection = { [weak self] nwConnection in self?.accept(nwConnection) }
        server.onStateChanged = { [weak self] state in self?.onListeningStateChanged?(state) }
        server.onReady = { [weak self] port in self?.onListenerReady?(port) }
    }

    func startListening(service: NWListener.Service? = nil) throws {
        try server.start(port: identity.listeningPort, service: service)
    }

    #if DEBUG
    func connect(host: String, port: UInt16) {
        guard configuredSecurityMode.permitsPlaintextNormalMessages else {
            fail(SecureSessionError.plaintextForbidden)
            return
        }
        expectedTrustedPeer = nil
        connectionMode = .debugPlaintext
        beginOutgoing(.host(host, port))
    }
    #endif

    func connect(endpoint: NWEndpoint, trustedPeer: TrustedPeer) {
        guard trustedPeer.trustState == .trusted else {
            fail(PeerNestLANError.authenticationFailed)
            return
        }
        expectedTrustedPeer = trustedPeer
        connectionMode = .authenticated
        beginOutgoing(.endpoint(endpoint))
    }

    func connectForPairing(endpoint: NWEndpoint) {
        expectedTrustedPeer = nil
        connectionMode = .pairing
        beginOutgoing(.endpoint(endpoint))
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        messageProcessingTask?.cancel()
        messageProcessingTask = nil
        connection?.stop()
        connection = nil
        Task { await secureSession?.close() }
        resetHandshake()
        setConnectionState(.disconnected)
    }

    func stop() {
        disconnect()
        server.stop()
    }

    func send<Payload: Encodable>(_ type: PeerMessageType, payload: Payload) async throws {
        guard let connection else { throw TransportError.notReady }
        let message = try PeerMessage(senderPeerID: identity.id, messageType: type, payload: payload)
        switch connectionMode {
        #if DEBUG
        case .debugPlaintext:
            guard handshakeState == .ready || [.hello, .helloAck, .error].contains(type) else {
                throw TransportError.notReady
            }
            try await connection.send(message)
        #endif
        case .authenticated:
            guard let secureSession,
                  handshakeState == .ready || [.hello, .helloAck, .error].contains(type),
                  !Self.securityControlTypes.contains(type) else {
                throw TransportError.notReady
            }
            let innerData = try PeerMessageCoding.encoder.encode(message)
            let envelope = try await secureSession.seal(messageType: type, plaintext: innerData)
            secureSessionSnapshot = await secureSession.snapshot()
            try await connection.send(PeerMessage(
                senderPeerID: identity.id,
                messageType: .encrypted,
                payload: envelope
            ))
        case .pairing, .undecided:
            throw TransportError.notReady
        }
    }

    func sendPairing(_ message: PairingWireMessage) async throws {
        guard let connection, connectionMode == .pairing else { throw TransportError.notReady }
        switch message {
        case let .hello(payload):
            try await sendRaw(.pairingHello, payload: payload, over: connection)
        case let .confirmation(payload):
            try await sendRaw(.pairingConfirmation, payload: payload, over: connection)
        case let .rejection(payload):
            try await sendRaw(.pairingRejection, payload: payload, over: connection)
        }
    }

    private func beginOutgoing(_ target: OutboundTarget) {
        guard connectionState != .connected && connectionState != .connecting else { return }
        outboundTarget = target
        isOutgoing = true
        manualDisconnect = false
        reconnectAttempt = 0
        openOutgoingConnection()
    }

    private func accept(_ nwConnection: NWConnection) {
        if connectionState == .connected || connectionState == .connecting {
            nwConnection.cancel()
            return
        }
        isOutgoing = false
        outboundTarget = nil
        expectedTrustedPeer = nil
        #if DEBUG
        connectionMode = configuredSecurityMode.permitsPlaintextNormalMessages ? .debugPlaintext : .undecided
        #else
        connectionMode = .undecided
        #endif
        manualDisconnect = false
        install(PeerConnection(connection: nwConnection, label: "PeerNest.IncomingConnection"))
    }

    private func openOutgoingConnection() {
        guard let outboundTarget else { return }
        let newConnection: PeerConnection
        switch outboundTarget {
        case let .host(host, port):
            do { newConnection = try PeerConnection(host: host, port: port) }
            catch { fail(error); return }
        case let .endpoint(endpoint):
            newConnection = PeerConnection(endpoint: endpoint)
        }
        install(newConnection)
    }

    private func install(_ newConnection: PeerConnection) {
        connection?.stop()
        connection = newConnection
        resetHandshake(keepingMode: true)
        newConnection.onStateChanged = { [weak self, weak newConnection] state in
            guard let self, newConnection === connection else { return }
            handleConnectionState(state)
        }
        newConnection.onMessage = { [weak self, weak newConnection] message in
            guard let self, newConnection === connection else { return }
            enqueue(message)
        }
        newConnection.start()
    }

    private func handleConnectionState(_ state: PeerConnectionState) {
        setConnectionState(state)
        switch state {
        case .connected:
            reconnectAttempt = 0
            switch connectionMode {
            #if DEBUG
            case .debugPlaintext:
                setHandshakeState(.exchangingHello)
                Task { [weak self] in await self?.sendHello() }
            #endif
            case .pairing:
                setHandshakeState(.idle)
                onPairingConnectionReady?()
            case .authenticated:
                setHandshakeState(.authenticating)
                Task { [weak self] in await self?.beginSecureHandshakeIfNeeded() }
            case .undecided:
                setHandshakeState(.idle)
            }
        case .failed, .disconnected:
            heartbeatTask?.cancel()
            heartbeatTask = nil
            if !manualDisconnect, isOutgoing, outboundTarget != nil { scheduleReconnect() }
        default:
            break
        }
    }

    private func enqueue(_ message: PeerMessage) {
        let previous = messageProcessingTask
        messageProcessingTask = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, !Task.isCancelled else { return }
            await process(message)
        }
    }

    private func process(_ message: PeerMessage) async {
        lastReceivedAt = Date()
        guard message.senderPeerID != identity.id else { fail(TransportError.samePeerIdentity); return }
        do {
            switch message.messageType {
            case .pairingHello, .pairingConfirmation, .pairingRejection:
                try handlePairing(message)
            case .secureSessionHello:
                try await handleSecureHello(message)
            case .encrypted:
                try await handleEncrypted(message)
            default:
                #if DEBUG
                if connectionMode == .debugPlaintext {
                    try handleApplication(message)
                    return
                }
                #endif
                throw SecureSessionError.plaintextForbidden
            }
        } catch {
            if error is SecureSessionError {
                authenticationFailureCount += 1
                if authenticationFailureCount >= 3 { fail(error) }
                else { onError?(error) }
            } else {
                fail(error)
            }
        }
    }

    private func handlePairing(_ message: PeerMessage) throws {
        guard connectionMode == .pairing || connectionMode == .undecided else {
            throw SecureSessionError.plaintextForbidden
        }
        if connectionMode == .undecided { connectionMode = .pairing }
        switch message.messageType {
        case .pairingHello:
            onPairingMessage?(.hello(try message.decodePayload(PairingHello.self)))
        case .pairingConfirmation:
            onPairingMessage?(.confirmation(try message.decodePayload(PairingConfirmation.self)))
        case .pairingRejection:
            onPairingMessage?(.rejection(try message.decodePayload(PairingRejection.self)))
        default:
            throw TransportError.messageBeforeHandshake
        }
    }

    private func beginSecureHandshakeIfNeeded(sessionID: UUID = UUID()) async {
        guard localSecureHello == nil, let cryptographicIdentity, let connection else {
            if cryptographicIdentity == nil { fail(TransportError.missingCryptographicIdentity) }
            return
        }
        do {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            ephemeralPrivateKey = privateKey
            let unsigned = UnsignedSecureSessionHello(
                messageID: UUID(),
                sessionID: sessionID,
                peerID: identity.id,
                protocolVersion: PeerProtocolConstants.version,
                capabilities: PeerCapability.allCases,
                publicIdentityKey: cryptographicIdentity.publicIdentityKey,
                ephemeralPublicKey: privateKey.publicKey.rawRepresentation,
                nonce: Self.randomNonce(),
                createdAt: Date()
            )
            let signingMaterial = try PeerMessageCoding.encoder.encode(unsigned)
            let hello = SecureSessionHello(
                messageID: unsigned.messageID,
                sessionID: unsigned.sessionID,
                peerID: unsigned.peerID,
                protocolVersion: unsigned.protocolVersion,
                capabilities: unsigned.capabilities,
                publicIdentityKey: unsigned.publicIdentityKey,
                ephemeralPublicKey: unsigned.ephemeralPublicKey,
                nonce: unsigned.nonce,
                createdAt: unsigned.createdAt,
                signature: try cryptographicIdentity.signature(for: signingMaterial)
            )
            localSecureHello = hello
            try await sendRaw(.secureSessionHello, payload: hello, over: connection)
            try await establishSecureSessionIfPossible()
        } catch { fail(error) }
    }

    private func handleSecureHello(_ message: PeerMessage) async throws {
        guard connectionMode == .authenticated || connectionMode == .undecided else {
            throw SecureSessionError.plaintextForbidden
        }
        let hello = try message.decodePayload(SecureSessionHello.self)
        guard hello.peerID == message.senderPeerID else { throw TransportError.identityMismatch }
        guard hello.protocolVersion == PeerProtocolConstants.version else {
            throw PeerNestLANError.protocolMismatch
        }
        guard let trusted = trustedPeerProvider(hello.peerID), trusted.trustState == .trusted else {
            throw PeerNestLANError.authenticationFailed
        }
        guard hello.publicIdentityKey == trusted.publicIdentityKey else {
            identityChangedHandler(hello.peerID, hello.publicIdentityKey)
            throw PeerNestLANError.identityChanged
        }
        guard expectedTrustedPeer?.peerID == nil || expectedTrustedPeer?.peerID == hello.peerID else {
            throw SecureSessionError.wrongPeer
        }
        if let expectedTrustedPeer, expectedTrustedPeer.publicIdentityKey != hello.publicIdentityKey {
            identityChangedHandler(hello.peerID, hello.publicIdentityKey)
            throw PeerNestLANError.identityChanged
        }
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: trusted.publicIdentityKey)
        guard signingKey.isValidSignature(hello.signature, for: try hello.signingMaterial()) else {
            throw PeerNestLANError.authenticationFailed
        }
        if let localSecureHello, localSecureHello.sessionID != hello.sessionID {
            throw SecureSessionError.wrongSession
        }
        connectionMode = .authenticated
        remoteSecureHello = hello
        if localSecureHello == nil { await beginSecureHandshakeIfNeeded(sessionID: hello.sessionID) }
        try await establishSecureSessionIfPossible()
    }

    private func establishSecureSessionIfPossible() async throws {
        guard secureSession == nil, let local = localSecureHello, let remote = remoteSecureHello,
              let privateKey = ephemeralPrivateKey, let trusted = trustedPeerProvider(remote.peerID) else { return }
        let transcript = SecureSessionKeyDerivation.transcript(
            sessionID: local.sessionID,
            firstPeerID: identity.id,
            secondPeerID: remote.peerID,
            firstNonce: local.nonce,
            secondNonce: remote.nonce
        )
        let key = try SecureSessionKeyDerivation.deriveKey(
            privateKey: privateKey,
            remotePublicKey: remote.ephemeralPublicKey,
            transcript: transcript
        )
        let session = AuthenticatedSecureSession(
            sessionID: local.sessionID,
            localPeerID: identity.id,
            remotePeerID: remote.peerID,
            remoteFingerprint: trusted.fingerprint,
            capabilities: PeerCapability.allCases.filter(remote.capabilities.contains),
            key: key
        )
        secureSession = session
        secureSessionSnapshot = await session.snapshot()
        setHandshakeState(.exchangingHello)
        await sendHello()
    }

    private func handleEncrypted(_ outerMessage: PeerMessage) async throws {
        guard connectionMode == .authenticated, let secureSession else {
            throw SecureSessionError.authenticationFailed
        }
        let envelope = try outerMessage.decodePayload(SecureEnvelope.self)
        guard envelope.senderPeerID == outerMessage.senderPeerID else { throw SecureSessionError.wrongPeer }
        let plaintext = try await secureSession.open(envelope)
        let inner = try PeerMessageCoding.decoder.decode(PeerMessage.self, from: plaintext)
        guard inner.senderPeerID == envelope.senderPeerID,
              inner.messageType == envelope.messageType,
              inner.protocolVersion == PeerProtocolConstants.version,
              !Self.securityControlTypes.contains(inner.messageType) else {
            throw SecureSessionError.authenticationFailed
        }
        secureSessionSnapshot = await secureSession.snapshot()
        authenticationFailureCount = 0
        try handleApplication(inner)
    }

    private func handleApplication(_ message: PeerMessage) throws {
        switch message.messageType {
        case .hello:
            let hello = try message.decodePayload(HelloPayload.self)
            guard hello.protocolVersion == PeerProtocolConstants.version else {
                throw PeerFrameError.unsupportedProtocolVersion(hello.protocolVersion)
            }
            guard hello.peerID == message.senderPeerID else { throw TransportError.identityMismatch }
            remotePeer = hello
            onRemotePeerChanged?(hello)
            receivedHello = true
            Task { [weak self] in await self?.sendHelloAck(to: hello.peerID) }
        case .helloAck:
            let ack = try message.decodePayload(HelloAckPayload.self)
            guard ack.acknowledgedPeerID == identity.id, ack.peerID == message.senderPeerID else {
                throw TransportError.identityMismatch
            }
            receivedHelloAck = true
        case .ping:
            let ping = try message.decodePayload(PingPayload.self)
            Task { [weak self] in try? await self?.send(.pong, payload: PongPayload(nonce: ping.nonce)) }
        case .pong:
            _ = try message.decodePayload(PongPayload.self)
        default:
            guard handshakeState == .ready else { throw TransportError.messageBeforeHandshake }
            onMessage?(message)
        }
        finishHandshakeIfPossible()
    }

    private func sendHello() async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        do {
            try await send(.hello, payload: HelloPayload(
                peerID: identity.id,
                displayName: identity.displayName,
                protocolVersion: PeerProtocolConstants.version,
                appVersion: version,
                capabilities: PeerCapability.allCases
            ))
        } catch { fail(error) }
    }

    private func sendHelloAck(to peerID: UUID) async {
        do {
            try await send(.helloAck, payload: HelloAckPayload(
                acknowledgedPeerID: peerID,
                peerID: identity.id,
                displayName: identity.displayName,
                protocolVersion: PeerProtocolConstants.version,
                capabilities: PeerCapability.allCases
            ))
        } catch { fail(error) }
    }

    private func sendRaw<Payload: Encodable>(
        _ type: PeerMessageType,
        payload: Payload,
        over connection: PeerConnection
    ) async throws {
        try await connection.send(PeerMessage(senderPeerID: identity.id, messageType: type, payload: payload))
    }

    private func finishHandshakeIfPossible() {
        guard receivedHello, receivedHelloAck, handshakeState != .ready else { return }
        setHandshakeState(.ready)
        startHeartbeat()
        onReady?()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, handshakeState == .ready {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(lastReceivedAt) > 30 { fail(TransportError.staleConnection); return }
                try? await send(.ping, payload: PingPayload(nonce: UUID()))
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = AutoConnectPolicy.retryDelay(attempt: reconnectAttempt - 1)
        setConnectionState(.reconnecting(attempt: reconnectAttempt))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !manualDisconnect else { return }
            openOutgoingConnection()
        }
    }

    private func resetHandshake(keepingMode: Bool = false) {
        receivedHello = false
        receivedHelloAck = false
        remotePeer = nil
        onRemotePeerChanged?(nil)
        ephemeralPrivateKey = nil
        localSecureHello = nil
        remoteSecureHello = nil
        secureSession = nil
        secureSessionSnapshot = nil
        authenticationFailureCount = 0
        if !keepingMode { connectionMode = .undecided }
        setHandshakeState(.idle)
    }

    private func fail(_ error: Error) {
        onError?(error)
        setHandshakeState(.failed(error.localizedDescription))
        connection?.stop()
    }

    private func setConnectionState(_ state: PeerConnectionState) {
        connectionState = state
        onConnectionStateChanged?(state)
    }

    private func setHandshakeState(_ state: PeerHandshakeState) {
        handshakeState = state
        onHandshakeStateChanged?(state)
    }

    private static let securityControlTypes: Set<PeerMessageType> = [
        .pairingHello, .pairingConfirmation, .pairingRejection, .secureSessionHello, .encrypted
    ]

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    enum TransportError: LocalizedError {
        case notReady
        case samePeerIdentity
        case identityMismatch
        case messageBeforeHandshake
        case staleConnection
        case missingCryptographicIdentity

        var errorDescription: String? {
            switch self {
            case .notReady: "The peer connection is not ready."
            case .samePeerIdentity: "PeerNest refused a connection to the same peer identity."
            case .identityMismatch: "The peer handshake identity was inconsistent."
            case .messageBeforeHandshake: "The peer sent synchronization data before the handshake completed."
            case .staleConnection: "The peer stopped responding to heartbeat messages."
            case .missingCryptographicIdentity: "PeerNest could not load its secure device identity."
            }
        }
    }
}
