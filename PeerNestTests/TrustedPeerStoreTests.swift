import Foundation
import Testing
@testable import PeerNest

@MainActor
struct TrustedPeerStoreTests {
    @Test func trustedPeerAndAutoConnectPreferencePersist() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = makePeer()
        let store = TrustedPeerStore(defaults: defaults)
        try store.save(peer)
        try store.setAutoConnect(false, peerID: peer.peerID)

        let restored = TrustedPeerStore(defaults: defaults).peer(id: peer.peerID)
        #expect(restored?.displayName == peer.displayName)
        #expect(restored?.autoConnectEnabled == false)
    }

    @Test func revokedPeerIsRejected() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = makePeer()
        let store = TrustedPeerStore(defaults: defaults)
        try store.save(peer)
        try store.forget(peerID: peer.peerID)
        #expect(try store.validate(peerID: peer.peerID, publicIdentityKey: peer.publicIdentityKey) == .revoked)
    }

    @Test func changedIdentityIsPersistentlyMarked() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = makePeer()
        let store = TrustedPeerStore(defaults: defaults)
        try store.save(peer)
        #expect(try store.validate(peerID: peer.peerID, publicIdentityKey: Data(repeating: 9, count: 32)) == .identityChanged)
        #expect(TrustedPeerStore(defaults: defaults).peer(id: peer.peerID)?.trustState == .identityChanged)
    }

    @Test func privateIdentityNeverUsesUserDefaults() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secureStore = InMemorySecureKeyStore()
        let identityStore = DeviceIdentityStore(keyStore: secureStore)
        _ = try await identityStore.identity()
        #expect(defaults.data(forKey: DeviceIdentityStore.keychainAccount) == nil)
        #expect(try secureStore.data(for: DeviceIdentityStore.keychainAccount) != nil)
    }

    private func makePeer() -> TrustedPeer {
        let key = Data(repeating: 1, count: 32)
        return TrustedPeer(
            peerID: UUID(),
            displayName: "Trusted Mac",
            publicIdentityKey: key,
            fingerprint: PeerFingerprintFormatter.string(for: key)
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "PeerNest.TrustedPeerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

