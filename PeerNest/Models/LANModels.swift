//
//  LANModels.swift
//  PeerNest
//

import Foundation
import Network

nonisolated enum PeerNestLANError: LocalizedError, Equatable, Sendable {
    case localNetworkPermissionDenied
    case discoveryFailed(String)
    case advertisementFailed(String)
    case peerUnavailable
    case pairingRejected
    case pairingExpired
    case pairingCodeMismatch
    case identityChanged
    case authenticationFailed
    case protocolMismatch
    case encryptionFailed
    case invitationRejected
    case unauthorizedOperation
    case connectionLost

    var errorDescription: String? {
        switch self {
        case .localNetworkPermissionDenied:
            "Allow PeerNest to access the local network in System Settings to find nearby devices."
        case .discoveryFailed:
            "PeerNest could not browse for nearby devices."
        case .advertisementFailed:
            "PeerNest could not make this Mac visible on the local network."
        case .peerUnavailable:
            "That device is no longer available."
        case .pairingRejected:
            "The pairing request was rejected."
        case .pairingExpired:
            "The pairing request expired. Start pairing again."
        case .pairingCodeMismatch:
            "The verification codes did not match. No trust was created."
        case .identityChanged:
            "This device’s security identity has changed. Automatic connection was blocked."
        case .authenticationFailed:
            "PeerNest could not authenticate the other device."
        case .protocolMismatch:
            "The other device uses an incompatible PeerNest protocol version."
        case .encryptionFailed:
            "PeerNest could not establish or use an encrypted connection."
        case .invitationRejected:
            "The folder invitation was rejected."
        case .unauthorizedOperation:
            "The requested folder operation is not allowed by this share’s access mode."
        case .connectionLost:
            "The connection to the other device was lost."
        }
    }

    /// Development-only context. Never display this string as normal UI copy.
    var diagnostic: String? {
        switch self {
        case let .discoveryFailed(value), let .advertisementFailed(value): value
        default: nil
        }
    }
}

nonisolated enum PeerInterfaceType: String, Codable, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case wired = "Wired"
    case loopback = "Loopback"
    case other = "Other"

    init(_ interface: NWInterface?) {
        switch interface?.type {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .ethernet
        case .loopback: self = .loopback
        case .other: self = .other
        case .cellular: self = .other
        case nil: self = .other
        @unknown default: self = .other
        }
    }
}

nonisolated enum PeerAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

nonisolated enum DiscoveredPairingStatus: String, Codable, Sendable {
    case available
    case unavailable
    case trusted
    case identityChanged
}

nonisolated struct BonjourPeerMetadata: Equatable, Sendable {
    let discoveryID: String?
    let protocolVersion: Int?
    let capabilities: Set<String>
    let allowsPairing: Bool

    var supportsCurrentProtocol: Bool {
        protocolVersion == PeerProtocolConstants.version
    }
}

/// A resolved Network.framework service endpoint. It deliberately contains no paths or share names.
nonisolated struct DiscoveredPeer: Identifiable, @unchecked Sendable {
    let id: String
    var discoveryID: String?
    var serviceName: String
    var endpoint: NWEndpoint
    var interfaceType: PeerInterfaceType
    var protocolVersion: Int?
    var capabilities: Set<String>
    var pairingStatus: DiscoveredPairingStatus
    var lastSeen: Date
    var availability: PeerAvailability

    var supportsCurrentProtocol: Bool {
        protocolVersion == PeerProtocolConstants.version
    }
}

nonisolated enum BonjourConstants {
    static let serviceType = "_peernest._tcp"
    static let protocolVersionKey = "pv"
    static let appVersionKey = "av"
    static let capabilitiesKey = "caps"
    static let discoveryIDKey = "did"
    static let pairingKey = "pair"
}
