//
//  FolderSelectionService.swift
//  PeerNest
//

import AppKit

@MainActor
struct FolderSelectionService {
    func selectFolder(startingAt directoryURL: URL? = nil) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Add a Shared Folder"
        panel.message = "Everything recursively contained in this folder will be shared with PeerNest."
        panel.prompt = "Add Shared Folder"
        panel.directoryURL = directoryURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
