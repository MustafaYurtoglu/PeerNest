//
//  FileHashing.swift
//  PeerNest
//

import CryptoKit
import Foundation

enum FileHashing {
    nonisolated static func sha256(of url: URL, readSize: Int = 1024 * 1024) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while !Task.isCancelled {
                guard let data = try handle.read(upToCount: readSize), !data.isEmpty else { break }
                hasher.update(data: data)
            }
            try Task.checkCancellation()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
