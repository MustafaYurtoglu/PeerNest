//
//  ShareAccessPolicy.swift
//  PeerNest
//

import Foundation

nonisolated enum ShareAccessPolicy {
    static func permitsOutgoingMutation(_ mapping: ShareMapping) -> Bool {
        guard mapping.isEnabled else { return false }
        return mapping.accessMode == .readWrite || mapping.localRole == .owner
    }

    static func permitsIncomingMutation(_ mapping: ShareMapping) -> Bool {
        guard mapping.isEnabled else { return false }
        return mapping.accessMode == .readWrite || mapping.localRole == .receiver
    }

    static func authorizeOutgoing(_ operation: SyncOperation, mapping: ShareMapping) throws {
        guard operation.sharedFolderID == mapping.localSharedFolderID,
              permitsOutgoingMutation(mapping) else {
            throw PeerNestLANError.unauthorizedOperation
        }
    }

    static func authorizeIncoming(
        _ operation: SyncOperation,
        destinationSharedFolderID: UUID,
        mapping: ShareMapping
    ) throws {
        guard destinationSharedFolderID == mapping.localSharedFolderID,
              operation.sharedFolderID == mapping.remoteSharedFolderID,
              permitsIncomingMutation(mapping) else {
            throw PeerNestLANError.unauthorizedOperation
        }
    }
}
