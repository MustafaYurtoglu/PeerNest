import Foundation

enum FinderContextMenuAction: Equatable, Sendable {
    case shareFolder
    case stopSharing
    case showInApp
    case showSharedFolderInApp(rootURL: URL)
}

enum FinderContextMenuPolicy {
    static func actions(
        for selectedURLs: [URL],
        sharedFolders: [FinderSharedFolderRecord],
        snapshotIsReliable: Bool = true,
        internalRootURLs: [URL] = [],
        fileManager: FileManager = .default
    ) -> [FinderContextMenuAction] {
        guard snapshotIsReliable,
              selectedURLs.count == 1,
              let selectedURL = selectedURLs.first,
              isEligibleDirectory(selectedURL, fileManager: fileManager),
              !isPeerNestInternal(selectedURL, internalRootURLs: internalRootURLs) else {
            return []
        }

        for folder in sharedFolders {
            let rootURL = folder.rootURL
            if SharedPathValidator.isSameLocation(rootURL, selectedURL) {
                return [.showInApp, .stopSharing]
            }
            if SharedPathValidator.contains(root: rootURL, candidate: selectedURL, allowRoot: false) {
                return [.showSharedFolderInApp(rootURL: rootURL)]
            }
        }

        guard (try? SharedFolderOverlapPolicy.validate(
            candidate: selectedURL,
            existingRoots: sharedFolders.map(\.rootURL)
        )) != nil else {
            return []
        }
        return [.shareFolder]
    }

    private static func isEligibleDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true,
              values.isPackage != true else {
            return false
        }
        return true
    }

    private static func isPeerNestInternal(_ url: URL, internalRootURLs: [URL]) -> Bool {
        let canonicalURL = SharedPathValidator.canonicalURL(url)
        if canonicalURL.pathComponents.contains(SharedItemIgnorePolicy.internalMetadataDirectoryName) {
            return true
        }
        return internalRootURLs.contains { internalRoot in
            SharedPathValidator.contains(root: internalRoot, candidate: canonicalURL)
        }
    }
}

enum FinderDirectoryScope {
    static func monitoredURLs(
        homeDirectory: URL,
        sharedFolders: [FinderSharedFolderRecord]
    ) -> Set<URL> {
        let homeURL = SharedPathValidator.canonicalURL(homeDirectory)
        var urls: Set<URL> = []
        if homeURL.path != "/" {
            urls.insert(homeURL)
        }

        for folder in sharedFolders {
            let rootURL = SharedPathValidator.canonicalURL(folder.rootURL)
            guard rootURL.path != "/",
                  !SharedPathValidator.contains(root: homeURL, candidate: rootURL) else {
                continue
            }
            urls.insert(rootURL)
        }
        return urls
    }
}
