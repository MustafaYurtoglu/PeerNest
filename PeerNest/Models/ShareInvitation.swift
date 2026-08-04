//
//  ShareInvitation.swift
//  PeerNest
//

import Foundation

nonisolated enum ShareInvitationState: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case expired
    case cancelled
}

nonisolated struct ShareInvitation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let senderPeerID: UUID
    let recipientPeerID: UUID
    let senderSharedFolderID: UUID
    let displayName: String
    let accessMode: SharedFolderAccessMode
    let createdAt: Date
    let expiresAt: Date
    let approximateItemCount: Int?
    let approximateTotalSize: Int64?
    var state: ShareInvitationState

    init(
        id: UUID = UUID(),
        senderPeerID: UUID,
        recipientPeerID: UUID,
        senderSharedFolderID: UUID,
        displayName: String,
        accessMode: SharedFolderAccessMode,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(15 * 60),
        approximateItemCount: Int? = nil,
        approximateTotalSize: Int64? = nil,
        state: ShareInvitationState = .pending
    ) {
        self.id = id
        self.senderPeerID = senderPeerID
        self.recipientPeerID = recipientPeerID
        self.senderSharedFolderID = senderSharedFolderID
        self.displayName = displayName
        self.accessMode = accessMode
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.approximateItemCount = approximateItemCount
        self.approximateTotalSize = approximateTotalSize
        self.state = state
    }

    func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }
}

nonisolated struct ShareInvitationResponse: Codable, Equatable, Sendable {
    let invitationID: UUID
    let accepted: Bool
    let receiverSharedFolderID: UUID?
    let accessMode: SharedFolderAccessMode
}
