//
//  DeviceIdentityStore.swift
//  PeerNest
//

import CryptoKit
import Foundation

nonisolated struct DeviceCryptographicIdentity: Sendable {
    let publicIdentityKey: Data
    let fingerprint: String
    fileprivate let signingPrivateKey: Curve25519.Signing.PrivateKey

    func signature(for data: Data) throws -> Data {
        try signingPrivateKey.signature(for: data)
    }

    func isValidSignature(_ signature: Data, for data: Data) -> Bool {
        signingPrivateKey.publicKey.isValidSignature(signature, for: data)
    }
}

nonisolated enum DeviceIdentityError: LocalizedError, Sendable {
    case invalidStoredIdentity

    var errorDescription: String? {
        "PeerNest’s saved device identity is invalid. Remove its Keychain item before trying again."
    }
}

actor DeviceIdentityStore {
    static let keychainAccount = "curve25519-signing-private-key-v1"

    private let keyStore: any SecureKeyStore
    private var cachedIdentity: DeviceCryptographicIdentity?

    init(keyStore: any SecureKeyStore = KeychainSecureKeyStore()) {
        self.keyStore = keyStore
    }

    func identity() throws -> DeviceCryptographicIdentity {
        if let cachedIdentity { return cachedIdentity }

        let privateKey: Curve25519.Signing.PrivateKey
        if let raw = try keyStore.data(for: Self.keychainAccount) {
            do { privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw) }
            catch { throw DeviceIdentityError.invalidStoredIdentity }
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
            try keyStore.save(privateKey.rawRepresentation, for: Self.keychainAccount)
        }

        let publicKey = privateKey.publicKey.rawRepresentation
        let identity = DeviceCryptographicIdentity(
            publicIdentityKey: publicKey,
            fingerprint: PeerFingerprintFormatter.string(for: publicKey),
            signingPrivateKey: privateKey
        )
        cachedIdentity = identity
        return identity
    }
}

nonisolated enum PeerFingerprintFormatter {
    static func string(for publicIdentityKey: Data) -> String {
        let digest = SHA256.hash(data: publicIdentityKey)
        return digest.map { String(format: "%02X", $0) }
            .joined()
            .chunked(every: 4)
            .joined(separator: " ")
    }

    static func shortDiscoveryID(peerID: UUID) -> String {
        String(SHA256.hash(data: Data(peerID.uuidString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

private nonisolated extension String {
    func chunked(every count: Int) -> [String] {
        guard count > 0 else { return [self] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: count, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<next]))
            index = next
        }
        return result
    }
}

