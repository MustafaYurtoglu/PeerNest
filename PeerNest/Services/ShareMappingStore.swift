//
//  ShareMappingStore.swift
//  PeerNest
//

import Foundation

@MainActor
final class ShareMappingStore {
    enum StoreError: LocalizedError, Equatable {
        case duplicateMapping
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .duplicateMapping: "That peer and folder are already mapped."
            case .persistenceFailed: "PeerNest could not save the accepted folder mapping."
            }
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var mappings: [ShareMapping]

    init(defaults: UserDefaults = .standard, storageKey: String = "shareMappings.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? PropertyListDecoder().decode([ShareMapping].self, from: data) {
            mappings = decoded
        } else {
            mappings = []
        }
    }

    func add(_ mapping: ShareMapping) throws {
        guard !mappings.contains(where: {
            $0.remotePeerID == mapping.remotePeerID &&
                ($0.localSharedFolderID == mapping.localSharedFolderID ||
                 $0.remoteSharedFolderID == mapping.remoteSharedFolderID)
        }) else { throw StoreError.duplicateMapping }
        mappings.append(mapping)
        try persist()
    }

    func save(_ mapping: ShareMapping) throws {
        if let index = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[index] = mapping
        } else {
            try add(mapping)
            return
        }
        try persist()
    }

    func stop(mappingID: UUID) throws {
        guard let index = mappings.firstIndex(where: { $0.id == mappingID }) else { return }
        mappings[index].isEnabled = false
        try persist()
    }

    func disableMappings(for peerID: UUID) throws {
        for index in mappings.indices where mappings[index].remotePeerID == peerID {
            mappings[index].isEnabled = false
        }
        try persist()
    }

    private func persist() throws {
        do { defaults.set(try PropertyListEncoder().encode(mappings), forKey: storageKey) }
        catch { throw StoreError.persistenceFailed }
    }
}

