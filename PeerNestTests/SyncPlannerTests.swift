import Foundation
import Testing
@testable import PeerNest

@MainActor
struct SyncPlannerTests {
    private let shareID = UUID()
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    @Test func missingDirectoriesComeBeforeFiles() throws {
        let source = [try directory("Nested"), try file("Nested/a.txt", hash: "a")]
        let plan = try makePlan(source: source, destination: [])
        #expect(plan.operations.map(\.type) == [.createDirectory, .createFile])
    }

    @Test func missingFilesAreCreated() throws {
        let plan = try makePlan(source: [try file("a.txt", hash: "a")], destination: [])
        #expect(plan.operations.first?.type == .createFile)
        #expect(plan.operations.first?.relativePath == "a.txt")
    }

    @Test func changedFileCreatesConflictCopy() throws {
        let plan = try makePlan(
            source: [try file("report.pdf", hash: "source")],
            destination: [try file("report.pdf", hash: "destination")]
        )
        #expect(plan.operations.count == 1)
        #expect(plan.operations[0].destinationRelativePath?.contains("Conflict from Peer A") == true)
    }

    @Test func conservativeInitialSyncDoesNotDeleteUnmatchedDestination() throws {
        let plan = try makePlan(source: [], destination: [try file("destination-only.txt", hash: "x")])
        #expect(plan.operations.isEmpty)
    }

    @Test func conflictsPreserveSourceAndDestinationPaths() throws {
        let plan = try makePlan(
            source: [try file("notes.txt", hash: "one")],
            destination: [try file("notes.txt", hash: "two")]
        )
        #expect(plan.operations[0].relativePath == "notes.txt")
        #expect(plan.operations[0].destinationRelativePath != "notes.txt")
        #expect(plan.conflicts == [plan.operations[0].destinationRelativePath!])
    }

    private func makePlan(source: [SyncManifestEntry], destination: [SyncManifestEntry]) throws -> SyncPlan {
        try SyncPlanner.planConservativeInitialPush(
            source: source,
            destination: destination,
            sourceSharedFolderID: shareID,
            sourcePeerName: "Peer A",
            now: now
        )
    }

    private func directory(_ path: String) throws -> SyncManifestEntry {
        try SyncManifestEntry(relativePath: path, itemType: .directory, size: 0, modificationDate: now)
    }

    private func file(_ path: String, hash: String) throws -> SyncManifestEntry {
        try SyncManifestEntry(relativePath: path, itemType: .file, size: 4, modificationDate: now, contentHash: hash)
    }
}
