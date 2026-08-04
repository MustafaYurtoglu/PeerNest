//
//  BonjourBrowser.swift
//  PeerNest
//

import Foundation
import Network

nonisolated struct BonjourDiscoveryRecord: @unchecked Sendable {
    let resultID: String
    let serviceName: String
    let endpoint: NWEndpoint
    let interfaceType: PeerInterfaceType
    let metadata: BonjourPeerMetadata
    let seenAt: Date
}

nonisolated struct BonjourDiscoveryRegistry: Sendable {
    private(set) var peersByID: [String: DiscoveredPeer] = [:]

    mutating func merge(
        records: [BonjourDiscoveryRecord],
        localDiscoveryID: String,
        pairingStatus: (BonjourDiscoveryRecord) -> DiscoveredPairingStatus
    ) -> [DiscoveredPeer] {
        let currentIDs = Set(records.map(\.resultID))
        for id in peersByID.keys where !currentIDs.contains(id) {
            peersByID[id]?.availability = .unavailable
        }

        for record in records where record.metadata.discoveryID != localDiscoveryID {
            let stableID = record.metadata.discoveryID ?? record.resultID
            if let duplicateID = peersByID.first(where: {
                $0.key != stableID && $0.value.discoveryID != nil && $0.value.discoveryID == record.metadata.discoveryID
            })?.key {
                peersByID.removeValue(forKey: duplicateID)
            }
            peersByID[stableID] = DiscoveredPeer(
                id: stableID,
                discoveryID: record.metadata.discoveryID,
                serviceName: record.serviceName,
                endpoint: record.endpoint,
                interfaceType: record.interfaceType,
                protocolVersion: record.metadata.protocolVersion,
                capabilities: record.metadata.capabilities,
                pairingStatus: pairingStatus(record),
                lastSeen: record.seenAt,
                availability: .available
            )
        }
        return peersByID.values.sorted {
            if $0.availability != $1.availability { return $0.availability == .available }
            return $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending
        }
    }

    mutating func markAllUnavailable() -> [DiscoveredPeer] {
        for key in peersByID.keys { peersByID[key]?.availability = .unavailable }
        return Array(peersByID.values)
    }
}

@MainActor
final class BonjourBrowser {
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    var onError: ((PeerNestLANError) -> Void)?

    private let localDiscoveryID: String
    private let statusProvider: (BonjourDiscoveryRecord) -> DiscoveredPairingStatus
    private let queue = DispatchQueue(label: "PeerNest.BonjourBrowser", qos: .utility)
    private var browser: NWBrowser?
    private var registry = BonjourDiscoveryRegistry()

    init(
        localPeerID: UUID,
        statusProvider: @escaping (BonjourDiscoveryRecord) -> DiscoveredPairingStatus = { _ in .available }
    ) {
        localDiscoveryID = PeerFingerprintFormatter.shortDiscoveryID(peerID: localPeerID)
        self.statusProvider = statusProvider
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BonjourConstants.serviceType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor [weak self, weak browser] in
                guard let self, browser === self.browser else { return }
                self.handle(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let records = results.compactMap(Self.record(from:))
            Task { @MainActor [weak self, weak browser] in
                guard let self, browser === self.browser else { return }
                let peers = self.registry.merge(
                    records: records,
                    localDiscoveryID: self.localDiscoveryID,
                    pairingStatus: self.statusProvider
                )
                self.onPeersChanged?(peers)
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        onPeersChanged?(registry.markAllUnavailable())
    }

    nonisolated static func metadata(from txtRecord: Data?) -> BonjourPeerMetadata {
        guard let txtRecord else {
            return BonjourPeerMetadata(discoveryID: nil, protocolVersion: nil, capabilities: [], allowsPairing: false)
        }
        let values = NetService.dictionary(fromTXTRecord: txtRecord)
        func string(_ key: String) -> String? {
            values[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        let capabilities = Set((string(BonjourConstants.capabilitiesKey) ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty })
        return BonjourPeerMetadata(
            discoveryID: string(BonjourConstants.discoveryIDKey).flatMap { $0.isEmpty ? nil : $0 },
            protocolVersion: string(BonjourConstants.protocolVersionKey).flatMap(Int.init),
            capabilities: capabilities,
            allowsPairing: string(BonjourConstants.pairingKey) == "1"
        )
    }

    private nonisolated static func record(from result: NWBrowser.Result) -> BonjourDiscoveryRecord? {
        guard case let .service(name, type, domain, interface) = result.endpoint,
              type == BonjourConstants.serviceType else { return nil }
        let txtRecord: Data?
        if case let .bonjour(record) = result.metadata { txtRecord = record.data }
        else { txtRecord = nil }
        let resultID = [name, type, domain, interface?.name ?? "any"].joined(separator: "|")
        return BonjourDiscoveryRecord(
            resultID: resultID,
            serviceName: name,
            endpoint: result.endpoint,
            interfaceType: PeerInterfaceType(interface),
            metadata: metadata(from: txtRecord),
            seenAt: Date()
        )
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            onError?(.discoveryFailed(String(describing: error)))
        case .waiting(let error):
            if case .posix(.EACCES) = error { onError?(.localNetworkPermissionDenied) }
        case .cancelled:
            onPeersChanged?(registry.markAllUnavailable())
        case .setup, .ready:
            break
        @unknown default:
            onError?(.discoveryFailed("Unknown browser state"))
        }
    }
}
