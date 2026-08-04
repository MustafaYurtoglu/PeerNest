//
//  PeerIdentity.swift
//  PeerNest
//

import CryptoKit
import Foundation

struct PeerIdentity: Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var instanceName: String
    var listeningPort: UInt16
}

struct DebugLaunchConfiguration: Equatable, Sendable {
    enum ConfigurationError: LocalizedError, Equatable {
        case missingValue(String)
        case invalidPort(String, String)
        case invalidTestNamespace(String)

        var errorDescription: String? {
            switch self {
            case let .missingValue(argument):
                "The debug launch argument \(argument) requires a value."
            case let .invalidPort(argument, value):
                "The value ‘\(value)’ for \(argument) must be a port from 1 through 65535."
            case let .invalidTestNamespace(value):
                "The test namespace ‘\(value)’ must contain only letters, numbers, hyphens, or underscores."
            }
        }
    }

    var instanceID: String?
    var instanceName: String?
    var listeningPort: UInt16?
    var peerHost: String?
    var peerPort: UInt16?
    var debugSharePath: String?
    var testNamespace: String?
    var integrationAutoStart = false
    var integrationAutoConnect = false

    static func parse(_ arguments: [String]) throws -> DebugLaunchConfiguration {
        #if DEBUG
        var result = DebugLaunchConfiguration()
        let valueArguments = Set([
            "--instance-id", "--instance-name", "--listen-port",
            "--peer-host", "--peer-port", "--debug-share-path", "--test-namespace"
        ])
        let flags = Set(["--integration-auto-start", "--integration-auto-connect"])
        let supported = valueArguments.union(flags)
        var index = arguments.first?.hasPrefix("--") == true ? 0 : 1

        while index < arguments.count {
            let argument = arguments[index]
            guard supported.contains(argument) else {
                index += 1
                continue
            }
            if flags.contains(argument) {
                if argument == "--integration-auto-start" { result.integrationAutoStart = true }
                if argument == "--integration-auto-connect" { result.integrationAutoConnect = true }
                index += 1
                continue
            }
            guard index + 1 < arguments.count,
                  !supported.contains(arguments[index + 1]) else {
                throw ConfigurationError.missingValue(argument)
            }
            let value = arguments[index + 1]
            switch argument {
            case "--instance-id": result.instanceID = value
            case "--instance-name": result.instanceName = value
            case "--listen-port": result.listeningPort = try parsePort(value, argument: argument)
            case "--peer-host": result.peerHost = value
            case "--peer-port": result.peerPort = try parsePort(value, argument: argument)
            case "--debug-share-path": result.debugSharePath = value
            case "--test-namespace": result.testNamespace = try parseTestNamespace(value)
            default: break
            }
            index += 2
        }
        return result
        #else
        return DebugLaunchConfiguration()
        #endif
    }

    private static func parsePort(_ value: String, argument: String) throws -> UInt16 {
        guard let number = UInt16(value), number > 0 else {
            throw ConfigurationError.invalidPort(argument, value)
        }
        return number
    }

    #if DEBUG
    private static func parseTestNamespace(_ value: String) throws -> String {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.count <= 48,
              value.unicodeScalars.allSatisfy(permitted.contains) else {
            throw ConfigurationError.invalidTestNamespace(value)
        }
        return value
    }
    #endif
}

#if DEBUG
struct DebugTestNamespace {
    let name: String
    let defaults: UserDefaults
    let rootURL: URL

    init?(name: String) {
        let suiteName = "com.mustafayurtoglu.PeerNest.integration.\(name)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.name = name
        rootURL = URL(fileURLWithPath: "/tmp/PeerNestIntegration/State/\(name)", isDirectory: true)
        let resetMarker = rootURL.appendingPathComponent("reset-defaults.request")
        if FileManager.default.fileExists(atPath: resetMarker.path) {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: resetMarker)
        }
        self.defaults = defaults
    }

    var appGroupURL: URL { rootURL.appendingPathComponent("AppGroup", isDirectory: true) }
    var recoveryURL: URL { rootURL.appendingPathComponent("Recovery", isDirectory: true) }
    var keychainService: String { "com.mustafayurtoglu.PeerNest.device-identity.integration.\(name)" }
}
#endif

@MainActor
final class PeerIdentityStore {
    private let defaults: UserDefaults
    private let identityKey = "peerIdentity.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identity(configuration: DebugLaunchConfiguration) -> PeerIdentity {
        let persisted = loadPersistedIdentity() ?? makeProductionIdentity()
        if loadPersistedIdentity() == nil {
            save(persisted)
        }

        return PeerIdentity(
            id: configuration.instanceID.map(Self.stableUUID(for:)) ?? persisted.id,
            displayName: configuration.instanceName ?? persisted.displayName,
            instanceName: configuration.instanceName ?? persisted.instanceName,
            listeningPort: configuration.listeningPort ?? persisted.listeningPort
        )
    }

    private func loadPersistedIdentity() -> PeerIdentity? {
        guard let data = defaults.data(forKey: identityKey) else { return nil }
        return try? PropertyListDecoder().decode(PeerIdentity.self, from: data)
    }

    private func makeProductionIdentity() -> PeerIdentity {
        let name = Host.current().localizedName ?? "This Mac"
        return PeerIdentity(id: UUID(), displayName: name, instanceName: "PeerNest", listeningPort: 0)
    }

    private func save(_ identity: PeerIdentity) {
        defaults.set(try? PropertyListEncoder().encode(identity), forKey: identityKey)
    }

    private static func stableUUID(for value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
