import Foundation
import Testing
@testable import PeerNest

@MainActor
struct AppliedOperationRegistryTests {
    @Test func remoteOperationIsSuppressed() async {
        let registry = AppliedOperationRegistry()
        let shareID = UUID()
        await registry.register(operationID: UUID(), sharedFolderID: shareID, relativePath: "file.txt", expectedHash: "expected")
        #expect(await registry.shouldSuppress(sharedFolderID: shareID, relativePath: "file.txt", resultingHash: "expected"))
        #expect(!(await registry.shouldSuppress(sharedFolderID: shareID, relativePath: "file.txt", resultingHash: "expected")))
    }

    @Test func localEditWithDifferentHashIsNotSuppressed() async {
        let registry = AppliedOperationRegistry()
        let shareID = UUID()
        await registry.register(operationID: UUID(), sharedFolderID: shareID, relativePath: "file.txt", expectedHash: "remote")
        #expect(!(await registry.shouldSuppress(sharedFolderID: shareID, relativePath: "file.txt", resultingHash: "local")))
    }

    @Test func remoteDeletionSuppressesOneReflectedWatcherEvent() async {
        let registry = AppliedOperationRegistry()
        let shareID = UUID()
        await registry.register(
            operationID: UUID(),
            sharedFolderID: shareID,
            relativePath: "deleted.txt",
            expectedHash: nil
        )
        #expect(await registry.shouldSuppress(
            sharedFolderID: shareID,
            relativePath: "deleted.txt",
            resultingHash: nil
        ))
        #expect(!(await registry.shouldSuppress(
            sharedFolderID: shareID,
            relativePath: "deleted.txt",
            resultingHash: nil
        )))
    }

    @Test func expiredEntryIsRemoved() async {
        let registry = AppliedOperationRegistry(lifetime: 1)
        let start = Date(timeIntervalSince1970: 10)
        let shareID = UUID()
        await registry.register(operationID: UUID(), sharedFolderID: shareID, relativePath: "file.txt", expectedHash: nil, now: start)
        await registry.purgeExpired(now: start.addingTimeInterval(2))
        #expect(await registry.pendingEntryCount() == 0)
    }

    @Test func duplicateOperationIDIsIdempotent() async {
        let registry = AppliedOperationRegistry()
        let operationID = UUID()
        #expect(await registry.claimOperation(operationID))
        #expect(!(await registry.claimOperation(operationID)))
    }
}
