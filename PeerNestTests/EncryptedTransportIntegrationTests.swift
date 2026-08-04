import Foundation
import Network
import Testing
@testable import PeerNest

@MainActor
struct EncryptedTransportIntegrationTests {
    @Test func trustedLoopbackConnectionCompletesEncryptedHandshake() async throws {
        let peerA = PeerIdentity(id: UUID(), displayName: "Secure A", instanceName: "A", listeningPort: 0)
        let peerB = PeerIdentity(id: UUID(), displayName: "Secure B", instanceName: "B", listeningPort: 0)
        let cryptoA = try await DeviceIdentityStore(keyStore: InMemorySecureKeyStore()).identity()
        let cryptoB = try await DeviceIdentityStore(keyStore: InMemorySecureKeyStore()).identity()
        let trustedA = TrustedPeer(
            peerID: peerB.id,
            displayName: peerB.displayName,
            publicIdentityKey: cryptoB.publicIdentityKey,
            fingerprint: cryptoB.fingerprint
        )
        let trustedB = TrustedPeer(
            peerID: peerA.id,
            displayName: peerA.displayName,
            publicIdentityKey: cryptoA.publicIdentityKey,
            fingerprint: cryptoA.fingerprint
        )
        let transportA = PeerTransport(
            identity: peerA,
            securityMode: .authenticated,
            cryptographicIdentity: cryptoA,
            trustedPeerProvider: { $0 == peerB.id ? trustedA : nil }
        )
        let transportB = PeerTransport(
            identity: peerB,
            securityMode: .authenticated,
            cryptographicIdentity: cryptoB,
            trustedPeerProvider: { $0 == peerA.id ? trustedB : nil }
        )
        defer { transportA.stop(); transportB.stop() }

        var listenerPort: UInt16?
        transportB.onListenerReady = { listenerPort = $0 }
        try transportB.startListening()
        try await waitUntil("dynamic listener port") { listenerPort != nil }
        let port = try #require(listenerPort)
        transportA.connect(
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            trustedPeer: trustedA
        )
        try await waitUntil("authenticated encrypted handshakes") {
            transportA.handshakeState == .ready && transportB.handshakeState == .ready
        }
        #expect(transportA.secureSessionSnapshot?.authenticatedRemoteFingerprint == cryptoB.fingerprint)
        #expect(transportB.secureSessionSnapshot?.authenticatedRemoteFingerprint == cryptoA.fingerprint)

        try await transportA.send(.ping, payload: PingPayload(nonce: UUID()))
        try await waitUntil("encrypted ping and pong") {
            (transportA.secureSessionSnapshot?.receiveSequenceNumber ?? 0) > 1 &&
                (transportB.secureSessionSnapshot?.receiveSequenceNumber ?? 0) > 1
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for \(description).")
        throw TestError.timeout
    }

    private enum TestError: Error { case timeout }
}
