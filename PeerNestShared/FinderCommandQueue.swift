//
//  FinderCommandQueue.swift
//  PeerNest
//

import Foundation

final class FinderCommandQueue: @unchecked Sendable {
    enum QueueError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            "The PeerNest App Group container is unavailable. Check signing and App Group configuration."
        }
    }

    private let fileManager: FileManager
    private let commandsDirectoryURL: URL
    private let consumedIDsURL: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(containerURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        guard let baseURL = containerURL
            ?? fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: PeerNestSharedConfiguration.appGroupIdentifier
            ) else {
            throw QueueError.appGroupUnavailable
        }

        commandsDirectoryURL = baseURL.appendingPathComponent("FinderCommands", isDirectory: true)
        consumedIDsURL = baseURL.appendingPathComponent("ConsumedFinderCommandIDs.plist")
        try fileManager.createDirectory(
            at: commandsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func enqueue(_ command: FinderCommand) throws {
        let data = try encoder.encode(command)
        let filename = String(format: "%.6f-%@.command", command.createdAt.timeIntervalSince1970, command.id.uuidString)
        try data.write(
            to: commandsDirectoryURL.appendingPathComponent(filename),
            options: .atomic
        )
    }

    func pendingCommands() throws -> [FinderCommand] {
        let consumedIDs = try loadConsumedIDs()
        let files = try fileManager.contentsOfDirectory(
            at: commandsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        var seenIDs = consumedIDs
        return files
            .filter { $0.pathExtension == "command" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let command = try? decoder.decode(FinderCommand.self, from: data),
                      seenIDs.insert(command.id).inserted else {
                    return nil
                }
                return command
            }
    }

    func markConsumed(_ command: FinderCommand) throws {
        var consumedIDs = try loadConsumedIDs()
        consumedIDs.insert(command.id)
        let data = try encoder.encode(Array(consumedIDs))
        try data.write(to: consumedIDsURL, options: .atomic)

        let matchingFiles = try fileManager.contentsOfDirectory(
            at: commandsDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(command.id.uuidString) }
        for file in matchingFiles {
            try? fileManager.removeItem(at: file)
        }
    }

    private func loadConsumedIDs() throws -> Set<UUID> {
        guard fileManager.fileExists(atPath: consumedIDsURL.path) else { return [] }
        let ids = try decoder.decode([UUID].self, from: Data(contentsOf: consumedIDsURL))
        return Set(ids)
    }
}
