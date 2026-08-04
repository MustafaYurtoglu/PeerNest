//
//  SharedPathValidator.swift
//  PeerNest
//

import Foundation

nonisolated enum SharedPathValidationError: LocalizedError, Equatable {
    case rootIsNotDirectory
    case pathIsOutsideRoot
    case rootIsNotDescendant
    case absoluteRelativePath
    case emptyRelativePath
    case malformedRelativePath
    case pathTraversal
    case symbolicLinkEscapesRoot

    var errorDescription: String? {
        switch self {
        case .rootIsNotDirectory: "The shared root must be a directory."
        case .pathIsOutsideRoot: "The item is outside the shared folder."
        case .rootIsNotDescendant: "The shared root itself is not a descendant path."
        case .absoluteRelativePath: "A synchronization path must be relative."
        case .emptyRelativePath: "A synchronization path cannot be empty."
        case .malformedRelativePath: "The relative path is malformed."
        case .pathTraversal: "The relative path attempts to escape the shared folder."
        case .symbolicLinkEscapesRoot: "A symbolic link points outside the shared folder."
        }
    }
}

nonisolated enum SharedPathValidator {
    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalURL(lhs).pathComponents == canonicalURL(rhs).pathComponents
    }

    static func contains(root: URL, candidate: URL, allowRoot: Bool = true) -> Bool {
        let rootComponents = canonicalURL(root).pathComponents
        let candidateComponents = canonicalURL(candidate).pathComponents
        guard candidateComponents.starts(with: rootComponents) else { return false }
        return allowRoot || candidateComponents.count > rootComponents.count
    }

    static func safeRelativePath(from root: URL, to candidate: URL) throws -> String {
        let lexicalRoot = root.standardizedFileURL
        let lexicalCandidate = candidate.standardizedFileURL
        let rootComponents = lexicalRoot.pathComponents
        let candidateComponents = lexicalCandidate.pathComponents

        guard candidateComponents.starts(with: rootComponents) else {
            throw SharedPathValidationError.pathIsOutsideRoot
        }
        guard candidateComponents.count > rootComponents.count else {
            throw SharedPathValidationError.rootIsNotDescendant
        }
        guard contains(root: root, candidate: candidate, allowRoot: false) else {
            throw SharedPathValidationError.symbolicLinkEscapesRoot
        }

        let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
        return try validatedRelativePath(relativeComponents.joined(separator: "/"))
    }

    static func destinationURL(in root: URL, relativePath: String) throws -> URL {
        let validatedPath = try validatedRelativePath(relativePath)
        let components = validatedPath.split(separator: "/", omittingEmptySubsequences: false)
        let canonicalRootComponents = canonicalURL(root).pathComponents
        var destination = root.standardizedFileURL
        for component in components {
            destination.appendPathComponent(String(component), isDirectory: false)
            guard canonicalURL(destination).pathComponents.starts(with: canonicalRootComponents) else {
                throw SharedPathValidationError.symbolicLinkEscapesRoot
            }
        }

        guard contains(root: root, candidate: destination, allowRoot: false) else {
            throw SharedPathValidationError.symbolicLinkEscapesRoot
        }
        return destination
    }

    static func validatedRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty else {
            throw SharedPathValidationError.emptyRelativePath
        }
        guard !relativePath.hasPrefix("/") else {
            throw SharedPathValidationError.absoluteRelativePath
        }
        guard !relativePath.contains("\0") else {
            throw SharedPathValidationError.malformedRelativePath
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." }) else {
            throw SharedPathValidationError.malformedRelativePath
        }
        guard !components.contains("..") else {
            throw SharedPathValidationError.pathTraversal
        }
        return components.joined(separator: "/")
    }
}

nonisolated enum SharedFolderOverlapError: LocalizedError, Equatable {
    case duplicate
    case coveredByExistingShare
    case containsExistingShare

    var errorDescription: String? {
        switch self {
        case .duplicate:
            "This folder is already shared with PeerNest."
        case .coveredByExistingShare:
            "This folder is already included by a shared parent folder. Overlapping shares are not supported yet."
        case .containsExistingShare:
            "This folder contains an existing shared folder. Overlapping shares are not supported yet."
        }
    }
}

nonisolated enum SharedFolderOverlapPolicy {
    static func validate(candidate: URL, existingRoots: [URL]) throws {
        for root in existingRoots {
            if SharedPathValidator.isSameLocation(candidate, root) {
                throw SharedFolderOverlapError.duplicate
            }
            if SharedPathValidator.contains(root: root, candidate: candidate, allowRoot: false) {
                throw SharedFolderOverlapError.coveredByExistingShare
            }
            if SharedPathValidator.contains(root: candidate, candidate: root, allowRoot: false) {
                throw SharedFolderOverlapError.containsExistingShare
            }
        }
    }
}
