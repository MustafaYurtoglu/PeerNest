//
//  BonjourAdvertiser.swift
//  PeerNest
//

import Foundation
import Network

nonisolated struct BonjourAdvertisement: Sendable {
    let service: NWListener.Service
    let serviceName: String
    let discoveryID: String
}

nonisolated enum BonjourAdvertiser {
    static func advertisement(
        identity: PeerIdentity,
        appVersion: String,
        allowsPairing: Bool
    ) -> BonjourAdvertisement {
        let serviceName = validServiceName(from: identity.displayName)
        let discoveryID = PeerFingerprintFormatter.shortDiscoveryID(peerID: identity.id)
        let values: [String: Data] = [
            BonjourConstants.protocolVersionKey: Data(String(PeerProtocolConstants.version).utf8),
            BonjourConstants.appVersionKey: Data(appVersion.utf8),
            BonjourConstants.capabilitiesKey: Data(PeerCapability.allCases.map(\.rawValue).joined(separator: ",").utf8),
            BonjourConstants.discoveryIDKey: Data(discoveryID.utf8),
            BonjourConstants.pairingKey: Data(allowsPairing ? "1".utf8 : "0".utf8)
        ]
        return BonjourAdvertisement(
            service: NWListener.Service(
                name: serviceName,
                type: BonjourConstants.serviceType,
                domain: nil,
                txtRecord: NetService.data(fromTXTRecord: values)
            ),
            serviceName: serviceName,
            discoveryID: discoveryID
        )
    }

    static func validServiceName(from displayName: String) -> String {
        let scalars = displayName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0 && $0 != "/"
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "PeerNest" : cleaned
        var result = ""
        for character in base {
            let candidate = result + String(character)
            guard candidate.lengthOfBytes(using: .utf8) <= 63 else { break }
            result = candidate
        }
        return result.isEmpty ? "PeerNest" : result
    }
}

