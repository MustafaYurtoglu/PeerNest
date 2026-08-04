//
//  PeerNestTests.swift
//  PeerNestTests
//

import Foundation
import Testing
@testable import PeerNest

@MainActor
struct PeerNestTests {
    private let root = URL(fileURLWithPath: "/tmp/PeerNestBoundaryTests/Files/Folder1", isDirectory: true)

    @Test func rootContainsDirectChild() throws {
        let child = root.appendingPathComponent("document.txt")
        #expect(try SharedPathValidator.safeRelativePath(from: root, to: child) == "document.txt")
    }

    @Test func rootContainsDeeplyNestedChild() throws {
        let child = root.appendingPathComponent("A/B/C/document.txt")
        #expect(try SharedPathValidator.safeRelativePath(from: root, to: child) == "A/B/C/document.txt")
    }

    @Test func siblingFolderIsRejected() {
        let sibling = root.deletingLastPathComponent().appendingPathComponent("Folder2/file.txt")
        #expect(throws: SharedPathValidationError.pathIsOutsideRoot) {
            try SharedPathValidator.safeRelativePath(from: root, to: sibling)
        }
    }

    @Test func parentFolderIsRejected() {
        #expect(throws: SharedPathValidationError.pathIsOutsideRoot) {
            try SharedPathValidator.safeRelativePath(from: root, to: root.deletingLastPathComponent())
        }
    }

    @Test func traversalIsRejected() {
        #expect(throws: SharedPathValidationError.pathTraversal) {
            try SharedPathValidator.destinationURL(in: root, relativePath: "Documents/../../Folder2/file.txt")
        }
    }

    @Test func absoluteNetworkPathIsRejected() {
        #expect(throws: SharedPathValidationError.absoluteRelativePath) {
            try SharedPathValidator.destinationURL(in: root, relativePath: "/tmp/escape.txt")
        }
    }

    @Test func symlinkEscapeIsRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNestSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let sharedRoot = base.appendingPathComponent("Shared", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(
            at: sharedRoot.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        #expect(throws: SharedPathValidationError.symbolicLinkEscapesRoot) {
            try SharedPathValidator.destinationURL(in: sharedRoot, relativePath: "escape/file.txt")
        }
    }

    @Test func sharedRootCannotBeDeleted() async {
        let registry = AppliedOperationRegistry()
        let applier = RemoteOperationApplier(registry: registry)
        await #expect(throws: RemoteOperationApplier.ApplicationError.cannotDeleteSharedRoot) {
            try await applier.validateDeletion(relativePath: "", rootURL: root)
        }
    }

    @Test func malformedRelativePathIsRejected() {
        #expect(throws: SharedPathValidationError.malformedRelativePath) {
            try SharedPathValidator.destinationURL(in: root, relativePath: "Documents//file.txt")
        }
    }

    @Test func duplicateSharedRootIsRejected() {
        #expect(throws: SharedFolderOverlapError.duplicate) {
            try SharedFolderOverlapPolicy.validate(candidate: root, existingRoots: [root])
        }
    }

    @Test func overlappingChildShareIsRejected() {
        let child = root.appendingPathComponent("Nested", isDirectory: true)
        #expect(throws: SharedFolderOverlapError.coveredByExistingShare) {
            try SharedFolderOverlapPolicy.validate(candidate: child, existingRoots: [root])
        }
    }

    @Test func overlappingParentShareIsRejected() {
        let child = root.appendingPathComponent("Nested", isDirectory: true)
        #expect(throws: SharedFolderOverlapError.containsExistingShare) {
            try SharedFolderOverlapPolicy.validate(candidate: root, existingRoots: [child])
        }
    }

    @Test func safeRelativePathRoundTrip() throws {
        let relativePath = "Nested/More/document.txt"
        let destination = try SharedPathValidator.destinationURL(in: root, relativePath: relativePath)
        #expect(try SharedPathValidator.safeRelativePath(from: root, to: destination) == relativePath)
    }

    @Test func ignoredMetadataPaths() {
        #expect(SharedItemIgnorePolicy.shouldIgnore(relativePath: ".DS_Store"))
        #expect(SharedItemIgnorePolicy.shouldIgnore(relativePath: ".peernest/state.plist"))
        #expect(SharedItemIgnorePolicy.shouldIgnore(relativePath: "Notes/.~draft.txt"))
        #expect(SharedItemIgnorePolicy.shouldIgnore(relativePath: "Notes/draft.txt~"))
        #expect(!SharedItemIgnorePolicy.shouldIgnore(relativePath: "Notes/document.txt"))
    }

    @Test func finderCommandsAreConsumedOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNestCommandQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = try FinderCommandQueue(containerURL: directory)
        let command = FinderCommand(type: .showInApp, selectedURL: root)
        try queue.enqueue(command)

        let firstRead = try queue.pendingCommands()
        #expect(firstRead.map(\.id) == [command.id])

        try queue.markConsumed(command)
        #expect(try queue.pendingCommands().isEmpty)

        try queue.markConsumed(command)
        #expect(try queue.pendingCommands().isEmpty)
    }
}
