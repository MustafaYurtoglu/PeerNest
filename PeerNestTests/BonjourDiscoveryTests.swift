import Foundation
import Network
import Testing
@testable import PeerNest

@MainActor
struct BonjourDiscoveryTests {
    @Test func localPeerIsExcludedAndDuplicatesMerge() {
        let localID = UUID()
        let localDiscoveryID = PeerFingerprintFormatter.shortDiscoveryID(peerID: localID)
        var registry = BonjourDiscoveryRegistry()
        let local = record(resultID: "local", discoveryID: localDiscoveryID)
        let remoteA = record(resultID: "remote-wifi", discoveryID: "remote-stable")
        let remoteB = record(resultID: "remote-ethernet", discoveryID: "remote-stable")

        let peers = registry.merge(records: [local, remoteA, remoteB], localDiscoveryID: localDiscoveryID) { _ in .available }
        #expect(peers.count == 1)
        #expect(peers.first?.discoveryID == "remote-stable")
    }

    @Test func removedPeerBecomesUnavailable() {
        var registry = BonjourDiscoveryRegistry()
        _ = registry.merge(records: [record(resultID: "one", discoveryID: "stable")], localDiscoveryID: "local") { _ in .available }
        let peers = registry.merge(records: [], localDiscoveryID: "local") { _ in .available }
        #expect(peers.first?.availability == .unavailable)
    }

    @Test func invalidTXTMetadataIsHandledSafely() {
        let metadata = BonjourBrowser.metadata(from: Data([0xFF, 0x00, 0xFE]))
        #expect(metadata.discoveryID == nil)
        #expect(metadata.protocolVersion == nil)
        #expect(metadata.capabilities.isEmpty)
        #expect(!metadata.allowsPairing)
    }

    @Test func unsupportedProtocolIsIdentified() {
        let txt = NetService.data(fromTXTRecord: [
            BonjourConstants.protocolVersionKey: Data("999".utf8),
            BonjourConstants.pairingKey: Data("1".utf8)
        ])
        let metadata = BonjourBrowser.metadata(from: txt)
        #expect(metadata.protocolVersion == 999)
        #expect(!metadata.supportsCurrentProtocol)
    }

    @Test func advertisedMetadataContainsNoShareOrPathKeys() {
        let identity = PeerIdentity(id: UUID(), displayName: "Test / Mac", instanceName: "Test", listeningPort: 0)
        let advertisement = BonjourAdvertiser.advertisement(identity: identity, appVersion: "1.0", allowsPairing: true)
        #expect(advertisement.serviceName == "Test  Mac")
        #expect(advertisement.discoveryID.count == 16)
    }

    private func record(resultID: String, discoveryID: String) -> BonjourDiscoveryRecord {
        BonjourDiscoveryRecord(
            resultID: resultID,
            serviceName: "Nearby Mac",
            endpoint: .service(name: "Nearby Mac", type: BonjourConstants.serviceType, domain: "local.", interface: nil),
            interfaceType: .wifi,
            metadata: BonjourPeerMetadata(
                discoveryID: discoveryID,
                protocolVersion: PeerProtocolConstants.version,
                capabilities: [PeerCapability.bidirectionalSync.rawValue],
                allowsPairing: true
            ),
            seenAt: Date()
        )
    }
}

