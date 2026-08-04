//
//  SyncStatus.swift
//  PeerNest
//

enum SyncStatus {
    case notConnected
    case connected

    var title: String {
        switch self {
        case .notConnected: "Not connected"
        case .connected: "Connected"
        }
    }
}
