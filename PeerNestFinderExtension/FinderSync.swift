//
//  FinderSync.swift
//  PeerNestFinderExtension
//

import AppKit
import FinderSync
import OSLog

@MainActor
final class PeerNestFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let commandQueue = try? FinderCommandQueue()
    private let sharedStateStore = try? FinderSharedStateSnapshotStore()
    private let logger = Logger(
        subsystem: PeerNestSharedConfiguration.mainAppBundleIdentifier,
        category: "finder-extension"
    )

    override init() {
        super.init()
        registerBadges()

        let state = readSharedState()
        refreshDirectoryScope(sharedFolders: state.folders)
        logger.info("Finder Sync extension initialized")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let selectedURLs = contextualURLs(for: menuKind)
        logger.debug(
            "Finder menu kind: \(menuKind.rawValue, privacy: .public), selection count: \(selectedURLs.count, privacy: .public)"
        )
        if let selectedURL = selectedURLs.first {
            logger.debug(
                "Finder selection name: \(selectedURL.lastPathComponent, privacy: .private(mask: .hash))"
            )
        }

        let state = readSharedState()
        refreshDirectoryScope(sharedFolders: state.folders)
        let actions = FinderContextMenuPolicy.actions(
            for: selectedURLs,
            sharedFolders: state.folders,
            snapshotIsReliable: state.isReliable,
            internalRootURLs: internalRootURLs
        )
        guard !actions.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        for action in actions {
            switch action {
            case .shareFolder:
                guard let selectedURL = selectedURLs.first else { continue }
                menu.addItem(menuItem(
                    title: NSLocalizedString("Share with PeerNest", comment: "Finder contextual menu"),
                    action: #selector(shareFolder(_:)),
                    url: selectedURL
                ))
            case .stopSharing:
                guard let selectedURL = selectedURLs.first else { continue }
                menu.addItem(menuItem(
                    title: NSLocalizedString("Stop Sharing with PeerNest", comment: "Finder contextual menu"),
                    action: #selector(stopSharing(_:)),
                    url: selectedURL
                ))
            case .showInApp:
                guard let selectedURL = selectedURLs.first else { continue }
                menu.addItem(menuItem(
                    title: NSLocalizedString("Show in PeerNest", comment: "Finder contextual menu"),
                    action: #selector(showInApp(_:)),
                    url: selectedURL
                ))
            case let .showSharedFolderInApp(rootURL):
                menu.addItem(menuItem(
                    title: NSLocalizedString("Show Shared Folder in PeerNest", comment: "Finder contextual menu"),
                    action: #selector(showInApp(_:)),
                    url: rootURL
                ))
            }
        }
        logger.debug("Finder menu actions produced: \(actions.count, privacy: .public)")
        return menu
    }

    private func contextualURLs(for menuKind: FIMenuKind) -> [URL] {
        switch menuKind {
        case .contextualMenuForItems:
            let selectedURLs = controller.selectedItemURLs() ?? []
            if !selectedURLs.isEmpty {
                return selectedURLs
            }
            return controller.targetedURL().map { [$0] } ?? []
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            if let targetedURL = controller.targetedURL() {
                return [targetedURL]
            }
            return controller.selectedItemURLs() ?? []
        case .toolbarItemMenu:
            return []
        @unknown default:
            return []
        }
    }

    override func requestBadgeIdentifier(for url: URL) {
        logger.debug(
            "Finder badge requested for: \(url.lastPathComponent, privacy: .private(mask: .hash))"
        )
        let state = readSharedState()
        guard let snapshot = state.snapshot,
              let folder = state.folders.first(where: {
                  SharedPathValidator.isSameLocation($0.rootURL, url)
              }) else {
            controller.setBadgeIdentifier("", for: url)
            return
        }
        controller.setBadgeIdentifier(
            snapshot.badgeState(for: folder.id).badgeIdentifier,
            for: url
        )
    }

    override func beginObservingDirectory(at url: URL) {
        logger.debug(
            "Began observing Finder directory: \(url.lastPathComponent, privacy: .private(mask: .hash))"
        )
    }

    override func endObservingDirectory(at url: URL) {
        logger.debug(
            "Ended observing Finder directory: \(url.lastPathComponent, privacy: .private(mask: .hash))"
        )
    }

    @objc private func shareFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        submit(.shareFolder, url: url, bookmarkData: bookmarkData)
    }

    @objc private func stopSharing(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        submit(.stopSharing, url: url)
    }

    @objc private func showInApp(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        submit(.showInApp, url: url)
    }

    private func submit(_ type: FinderCommandType, url: URL, bookmarkData: Data? = nil) {
        guard let commandQueue else {
            logger.error("Finder command queue unavailable")
            NSSound.beep()
            return
        }

        do {
            let command = FinderCommand(
                type: type,
                selectedURL: SharedPathValidator.canonicalURL(url),
                bookmarkData: bookmarkData
            )
            try commandQueue.enqueue(command)
            logger.info("Finder command queued: \(type.rawValue, privacy: .public)")
            openMainApplication()
        } catch {
            logger.error("Finder command queue error: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func readSharedState() -> SharedState {
        guard let sharedStateStore else {
            logger.error("Finder shared-state store unavailable")
            return SharedState(snapshot: nil, folders: [], isReliable: false)
        }
        switch sharedStateStore.readDefensively() {
        case .missing:
            logger.debug("Finder shared-state snapshot missing; treating the share list as empty")
            return SharedState(snapshot: nil, folders: [], isReliable: true)
        case let .valid(snapshot):
            logger.debug(
                "Finder shared-state snapshot read: \(snapshot.folders.count, privacy: .public) folders, stale: \(snapshot.isStale(), privacy: .public)"
            )
            return SharedState(snapshot: snapshot, folders: snapshot.folders, isReliable: true)
        case let .corrupt(error):
            logger.error("Finder shared-state snapshot rejected: \(error.localizedDescription, privacy: .public)")
            return SharedState(snapshot: nil, folders: [], isReliable: false)
        }
    }

    private func refreshDirectoryScope(sharedFolders: [FinderSharedFolderRecord]) {
        let urls = FinderDirectoryScope.monitoredURLs(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            sharedFolders: sharedFolders
        )
        guard controller.directoryURLs != urls else { return }
        controller.directoryURLs = urls
        logger.info("Registered \(urls.count, privacy: .public) Finder directory scope roots")
    }

    private var internalRootURLs: [URL] {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PeerNestSharedConfiguration.appGroupIdentifier
        ) else { return [] }
        return [url]
    }

    private func registerBadges() {
        let definitions: [(FinderBadgeState, String, String)] = [
            (.upToDate, "checkmark.circle.fill", "PeerNest: Up to Date"),
            (.syncing, "arrow.triangle.2.circlepath.circle.fill", "PeerNest: Syncing"),
            (.offlineChangesPending, "clock.badge.exclamationmark", "PeerNest: Offline Changes Pending"),
            (.conflict, "exclamationmark.triangle.fill", "PeerNest: Conflict"),
            (.paused, "pause.circle.fill", "PeerNest: Paused"),
            (.error, "exclamationmark.circle.fill", "PeerNest: Error"),
            (.unknown, "circle.dashed", "PeerNest: Status Unknown")
        ]
        for (state, symbol, label) in definitions {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { continue }
            image.isTemplate = true
            controller.setBadgeImage(image, label: label, forBadgeIdentifier: state.badgeIdentifier)
        }
    }

    private func menuItem(title: String, action: Selector, url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        return item
    }

    private func openMainApplication() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: PeerNestSharedConfiguration.mainAppBundleIdentifier
        ) else {
            logger.error("PeerNest main application was not found")
            NSSound.beep()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [logger] _, error in
            if let error {
                logger.error("Could not open PeerNest: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct SharedState {
    let snapshot: FinderSharedStateSnapshot?
    let folders: [FinderSharedFolderRecord]
    let isReliable: Bool
}
