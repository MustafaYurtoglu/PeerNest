import Foundation
import Testing
@testable import PeerNest

@MainActor
struct LocalhostSynchronizationIntegrationTests {
    @Test func liveFileEventsSynchronizeInBothDirectionsWithoutEchoing() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNestLocalhostIntegration-\(UUID().uuidString)", isDirectory: true)
        let rootA = base.appendingPathComponent("A", isDirectory: true)
        let rootB = base.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let initialA = Data("initial A".utf8)
        let initialB = Data("initial B".utf8)
        try initialA.write(to: rootA.appendingPathComponent("initial-a.txt"))
        try initialB.write(to: rootB.appendingPathComponent("initial-b.txt"))
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteA = "PeerNestIntegration.A.\(UUID().uuidString)"
        let suiteB = "PeerNestIntegration.B.\(UUID().uuidString)"
        let defaultsA = try #require(UserDefaults(suiteName: suiteA))
        let defaultsB = try #require(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let managerA = SharedFolderManager(
            bookmarkStore: DebugUnscopedBookmarkStore(),
            persistence: SharedFolderPersistenceService(defaults: defaultsA)
        )
        let managerB = SharedFolderManager(
            bookmarkStore: DebugUnscopedBookmarkStore(),
            persistence: SharedFolderPersistenceService(defaults: defaultsB)
        )
        _ = try managerA.addFolder(at: rootA)
        _ = try managerB.addFolder(at: rootB)
        defer {
            managerA.stopAll()
            managerB.stopAll()
        }

        let firstPort = UInt16(Int.random(in: 54_000...58_000))
        let coordinatorA = PeerSyncCoordinator(
            identity: PeerIdentity(id: UUID(), displayName: "Integration A", instanceName: "A", listeningPort: firstPort),
            manager: managerA
        )
        let coordinatorB = PeerSyncCoordinator(
            identity: PeerIdentity(id: UUID(), displayName: "Integration B", instanceName: "B", listeningPort: firstPort + 1),
            manager: managerB
        )
        defer {
            coordinatorA.stop()
            coordinatorB.stop()
        }
        var observedEventsA: [FileChangeEvent] = []
        var observedEventsB: [FileChangeEvent] = []
        managerA.onEvents = { events in
            observedEventsA.append(contentsOf: events)
            coordinatorA.handleLocalEvents(events)
        }
        managerB.onEvents = { events in
            observedEventsB.append(contentsOf: events)
            coordinatorB.handleLocalEvents(events)
        }

        coordinatorA.startListening()
        coordinatorB.startListening()
        try await Task.sleep(for: .milliseconds(300))
        coordinatorA.connect(host: "127.0.0.1", port: firstPort + 1)

        try await waitUntil("both handshakes become ready") {
            coordinatorA.handshakeState == .ready
                && coordinatorB.handshakeState == .ready
                && coordinatorA.mapping != nil
                && coordinatorB.mapping != nil
        }

        coordinatorA.runInitialSync()
        coordinatorB.runInitialSync()
        try await waitUntil("initial A content reaches B") {
            (try? Data(contentsOf: rootB.appendingPathComponent("initial-a.txt"))) == initialA
        }
        try await waitUntil("initial B content reaches A") {
            (try? Data(contentsOf: rootA.appendingPathComponent("initial-b.txt"))) == initialB
        }

        let fromA = Data("from A".utf8)
        try fromA.write(to: rootA.appendingPathComponent("from-a.txt"))
        try await waitUntil("A watcher reports the new file") {
            observedEventsA.contains { $0.relativePath == "from-a.txt" }
        }
        try await waitUntil("A file reaches B") {
            (try? Data(contentsOf: rootB.appendingPathComponent("from-a.txt"))) == fromA
        }

        let fromB = Data("from B".utf8)
        try fromB.write(to: rootB.appendingPathComponent("from-b.txt"))
        try await waitUntil("B watcher reports the new file") {
            observedEventsB.contains { $0.relativePath == "from-b.txt" }
        }
        try await waitUntil("B file reaches A") {
            (try? Data(contentsOf: rootA.appendingPathComponent("from-b.txt"))) == fromB
        }

        let burstOne = Data("burst one".utf8)
        let burstTwo = Data("burst two".utf8)
        try burstOne.write(to: rootA.appendingPathComponent("burst-one.txt"))
        try await Task.sleep(for: .milliseconds(700))
        try burstTwo.write(to: rootA.appendingPathComponent("burst-two.txt"))
        try await waitUntil("an event arriving during processing does not cancel either transfer") {
            (try? Data(contentsOf: rootB.appendingPathComponent("burst-one.txt"))) == burstOne
                && (try? Data(contentsOf: rootB.appendingPathComponent("burst-two.txt"))) == burstTwo
        }

        try await Task.sleep(for: .seconds(2))
        #expect(coordinatorA.pendingOperationCount == 0)
        #expect(coordinatorB.pendingOperationCount == 0)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 15,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting for \(description).")
        throw IntegrationError.timeout
    }

    private enum IntegrationError: Error { case timeout }
}
