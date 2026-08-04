//
//  SharedItemIgnorePolicy.swift
//  PeerNest
//

import Foundation

nonisolated enum SharedItemIgnorePolicy {
    static let internalMetadataDirectoryName = ".peernest"

    static func shouldIgnore(relativePath: String) -> Bool {
        guard let validatedPath = try? SharedPathValidator.validatedRelativePath(relativePath) else {
            return true
        }

        let components = validatedPath.split(separator: "/").map(String.init)
        guard let name = components.last else { return true }

        if components.contains(internalMetadataDirectoryName) || name == ".DS_Store" {
            return true
        }

        return name.hasPrefix(".~")
            || (name.hasPrefix("#") && name.hasSuffix("#"))
            || name.hasSuffix("~")
            || name.hasSuffix(".swp")
            || name.hasSuffix(".tmp")
    }
}
