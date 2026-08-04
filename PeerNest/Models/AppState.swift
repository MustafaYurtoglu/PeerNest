//
//  AppState.swift
//  PeerNest
//

import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppState {
    struct PresentedAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct PresentedNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var sharedFolders: [SharedFolder] = []
    var selectedSharedFolderID: UUID?
    private(set) var recentFileSystemEvents: [FileChangeEvent] = []
    private(set) var synchronizationActivity: [SyncActivity] = []
    private(set) var syncStatus: SyncStatus = .notConnected
    private(set) var peerIdentity: PeerIdentity
    private(set) var connectionState: PeerConnectionState = .setup
    private(set) var listeningState: PeerConnectionState = .setup
    private(set) var handshakeState: PeerHandshakeState = .idle
    private(set) var connectedPeer: HelloPayload?
    private(set) var shareMapping: ShareMapping?
    private(set) var initialSyncState: InitialSyncState = .idle
    private(set) var pendingOperationCount = 0
    private(set) var transferProgress: Double?
    private(set) var latestSynchronizationError: String?
    private(set) var nearbyPeers: [DiscoveredPeer] = []
    private(set) var trustedPeers: [TrustedPeer] = []
    private(set) var shareMappings: [ShareMapping] = []
    private(set) var pairingState: PairingState = .idle
    private(set) var pairingPeerDisplayName: String?
    private(set) var pairingActivities: [PairingActivity] = []
    private(set) var incomingPairingRequest: PairingHello?
    private(set) var incomingInvitation: ShareInvitation?
    private(set) var localSecurityFingerprint: String?
    private(set) var advertisedServiceName: String?
    private(set) var activeListenerPort: UInt16?
    private(set) var syncHealth = SyncHealth()
    private(set) var reconciliationProgress = ReconciliationProgress()
    private(set) var journalOperations: [JournaledSyncOperation] = []
    private(set) var conflicts: [ConflictRecord] = []
    private(set) var trashRecords: [TrashRecord] = []
    private(set) var storedVersions: [StoredFileVersion] = []
    private(set) var retentionPolicy = RetentionPolicy()
    var isRecoveryCenterSelected = false
    private(set) var isSynchronizationPaused = false
    private(set) var localNetworkState: LocalNetworkState = .reconnecting
    private(set) var lastSuccessfulSync: Date?
    private(set) var lastFinderCommandReceived: Date?
    private(set) var lastBadgeSnapshotPublished: Date?
    private(set) var unresolvedConflictCount = 0
    var selectedTrustedPeerID: UUID?
    var selectedNearbyPeerID: String?
    var debugRemoteHost: String
    var debugRemotePort: String
    var debugListeningPort: String
    var presentedAlert: PresentedAlert?
    var presentedNotice: PresentedNotice?
    @ObservationIgnored var onMainWindowRequested: (() -> Void)?

    var overallSyncState: OverallSyncState {
        SyncStateAggregator.state(
            isPaused: isSynchronizationPaused,
            latestError: latestSynchronizationError,
            unresolvedConflictCount: unresolvedConflictCount,
            isReconciling: reconciliationProgress.state != .idle
                && reconciliationProgress.state != .completed
                && reconciliationProgress.state != .failed,
            transferProgress: transferProgress,
            pendingOperationCount: pendingOperationCount,
            isConnected: handshakeState == .ready,
            hasEnabledFolders: sharedFolders.contains(where: \.isEnabled)
        )
    }

    var menuBarState: MenuBarState {
        let online = trustedPeers.filter(isOnline)
        let connectedNames = trustedPeers.filter(isConnected).map(\.displayName)
        return MenuBarState(
            overallState: overallSyncState,
            onlineTrustedPeerCount: online.count,
            offlineTrustedPeerCount: max(0, trustedPeers.count - online.count),
            connectedPeerNames: connectedNames,
            pendingOperationCount: pendingOperationCount,
            unresolvedConflictCount: unresolvedConflictCount,
            activeTransfer: transferProgress.map {
                ActiveTransferPresentation(
                    relativePath: "Current file",
                    direction: .upload,
                    progress: $0,
                    canCancelSafely: false
                )
            },
            lastSuccessfulSync: lastSuccessfulSync
        )
    }

    var selectedSharedFolder: SharedFolder? {
        sharedFolders.first { $0.id == selectedSharedFolderID }
    }

    var mappedSharedFolder: SharedFolder? {
        guard let shareMapping else { return nil }
        return sharedFolders.first { $0.id == shareMapping.localSharedFolderID }
    }

    var selectedTrustedPeer: TrustedPeer? {
        trustedPeers.first { $0.peerID == selectedTrustedPeerID }
    }

    var selectedNearbyPeer: DiscoveredPeer? {
        nearbyPeers.first { $0.id == selectedNearbyPeerID }
    }

    var pairingCode: String? {
        if case let .awaitingCodeConfirmation(code, _) = pairingState { return code }
        return nil
    }

    var pairingExpiresAt: Date? {
        if case let .awaitingCodeConfirmation(_, expiresAt) = pairingState { return expiresAt }
        return incomingPairingRequest?.expiresAt
    }

    var showsPairingPresentation: Bool {
        switch pairingState {
        case .idle, .rejected, .expired, .failed: incomingPairingRequest != nil
        default: true
        }
    }

    private let folderSelectionService: FolderSelectionService
    private let sharedFolderManager: SharedFolderManager
    private let finderCommandQueue: FinderCommandQueue?
    private let finderBadgeStore: FinderBadgeSnapshotStore?
    private let finderSharedStateStore: FinderSharedStateSnapshotStore?
    private let debugConfiguration: DebugLaunchConfiguration
    private let deviceIdentityStore: DeviceIdentityStore
    private let trustedPeerStore: TrustedPeerStore
    private let shareMappingStore: ShareMappingStore
    private let recoveryRepository: RecoveryRepository?
    private var syncCoordinator: PeerSyncCoordinator!
    private var pairingCoordinator: PairingCoordinator?
    private var bonjourBrowser: BonjourBrowser?
    private var commandPollingTask: Task<Void, Never>?
    private var hasLaunched = false
    private var isConsumingFinderCommands = false
    private var startupError: Error?
    private var recoveryStartupError: Error?
    private var manuallyPausedPeerIDs: Set<UUID> = []
    private var isDebugModeActive = false
    #if DEBUG
    private var lastDebugConnectionLog: String?
    private var debugInitialSyncStarted = false
    #endif

    init() {
        let configuration: DebugLaunchConfiguration
        do {
            configuration = try DebugLaunchConfiguration.parse(ProcessInfo.processInfo.arguments)
            startupError = nil
        } catch {
            configuration = DebugLaunchConfiguration()
            startupError = error
        }
        debugConfiguration = configuration
        folderSelectionService = FolderSelectionService()

        #if DEBUG
        if let namespaceName = configuration.testNamespace,
           let namespace = DebugTestNamespace(name: namespaceName) {
            try? FileManager.default.createDirectory(
                at: namespace.appGroupURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            sharedFolderManager = SharedFolderManager(
                bookmarkStore: DebugUnscopedBookmarkStore(),
                persistence: SharedFolderPersistenceService(defaults: namespace.defaults)
            )
            finderCommandQueue = try? FinderCommandQueue(containerURL: namespace.appGroupURL)
            finderBadgeStore = try? FinderBadgeSnapshotStore(containerURL: namespace.appGroupURL)
            finderSharedStateStore = try? FinderSharedStateSnapshotStore(containerURL: namespace.appGroupURL)
            deviceIdentityStore = DeviceIdentityStore(
                keyStore: KeychainSecureKeyStore(service: namespace.keychainService)
            )
            trustedPeerStore = TrustedPeerStore(defaults: namespace.defaults)
            shareMappingStore = ShareMappingStore(defaults: namespace.defaults)
            do {
                recoveryRepository = try RecoveryRepository(rootURL: namespace.recoveryURL)
                recoveryStartupError = nil
            } catch {
                recoveryRepository = nil
                recoveryStartupError = error
            }
        } else {
            sharedFolderManager = SharedFolderManager()
            finderCommandQueue = try? FinderCommandQueue()
            finderBadgeStore = try? FinderBadgeSnapshotStore()
            finderSharedStateStore = try? FinderSharedStateSnapshotStore()
            deviceIdentityStore = DeviceIdentityStore()
            trustedPeerStore = TrustedPeerStore()
            shareMappingStore = ShareMappingStore()
            do {
                recoveryRepository = try RecoveryRepository.openDefault()
                recoveryStartupError = nil
            } catch {
                recoveryRepository = nil
                recoveryStartupError = error
            }
        }
        #else
        sharedFolderManager = SharedFolderManager()
        finderCommandQueue = try? FinderCommandQueue()
        finderBadgeStore = try? FinderBadgeSnapshotStore()
        finderSharedStateStore = try? FinderSharedStateSnapshotStore()
        deviceIdentityStore = DeviceIdentityStore()
        trustedPeerStore = TrustedPeerStore()
        shareMappingStore = ShareMappingStore()
        do {
            recoveryRepository = try RecoveryRepository.openDefault()
            recoveryStartupError = nil
        } catch {
            recoveryRepository = nil
            recoveryStartupError = error
        }
        #endif
        trustedPeers = trustedPeerStore.peers
        shareMappings = shareMappingStore.mappings

        #if DEBUG
        let identityDefaults = configuration.testNamespace
            .flatMap(DebugTestNamespace.init(name:))?.defaults ?? .standard
        #else
        let identityDefaults = UserDefaults.standard
        #endif
        let resolvedIdentity = PeerIdentityStore(defaults: identityDefaults).identity(configuration: debugConfiguration)
        peerIdentity = resolvedIdentity
        debugRemoteHost = debugConfiguration.peerHost ?? "127.0.0.1"
        debugRemotePort = debugConfiguration.peerPort.map(String.init) ?? ""
        debugListeningPort = resolvedIdentity.listeningPort == 0 ? "" : String(resolvedIdentity.listeningPort)
        configureManager()
        rebuildCoordinator(identity: peerIdentity)
    }

    init(
        folderSelectionService: FolderSelectionService,
        sharedFolderManager: SharedFolderManager,
        finderCommandQueue: FinderCommandQueue?
    ) {
        self.folderSelectionService = folderSelectionService
        self.sharedFolderManager = sharedFolderManager
        self.finderCommandQueue = finderCommandQueue
        finderBadgeStore = nil
        finderSharedStateStore = nil
        deviceIdentityStore = DeviceIdentityStore(keyStore: InMemorySecureKeyStore())
        trustedPeerStore = TrustedPeerStore(defaults: UserDefaults(suiteName: "PeerNest.AppState.Tests") ?? .standard)
        shareMappingStore = ShareMappingStore(defaults: UserDefaults(suiteName: "PeerNest.AppState.Tests") ?? .standard)
        recoveryRepository = try? RecoveryRepository(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerNest-AppState-\(UUID().uuidString)", isDirectory: true))
        recoveryStartupError = nil
        trustedPeers = trustedPeerStore.peers
        shareMappings = shareMappingStore.mappings
        debugConfiguration = DebugLaunchConfiguration()
        peerIdentity = PeerIdentityStore().identity(configuration: debugConfiguration)
        debugRemoteHost = "127.0.0.1"
        debugRemotePort = ""
        debugListeningPort = ""
        configureManager()
        rebuildCoordinator(identity: peerIdentity)
    }

    func launch(startServices: Bool = true) {
        guard !hasLaunched else { return }
        hasLaunched = true
        sharedFolderManager.restore()
        sharedFolders = sharedFolderManager.sharedFolders
        selectedSharedFolderID = selectedSharedFolderID ?? sharedFolders.first?.id
        publishFinderSnapshot()

        if let startupError { show(startupError) }
        if let recoveryStartupError { show(recoveryStartupError) }
        #if DEBUG
        let startsDebugIntegration = debugConfiguration.testNamespace != nil
            && debugConfiguration.integrationAutoStart
        if let path = debugConfiguration.debugSharePath {
            Task { @MainActor [weak self] in
                await self?.registerDebugFolder(path: path)
                if startsDebugIntegration { await self?.startDebugIntegrationHarness() }
            }
        } else if startsDebugIntegration {
            Task { @MainActor [weak self] in await self?.startDebugIntegrationHarness() }
        }
        #else
        let startsDebugIntegration = false
        #endif

        commandPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.processPendingFinderCommands()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if startServices && !startsDebugIntegration {
            Task { @MainActor [weak self] in await self?.startLocalNetworkServices() }
        }
        Task { @MainActor [weak self] in await self?.runStartupRecovery() }
    }

    func addSharedFolder() async {
        guard let url = await folderSelectionService.selectFolder() else { return }
        do {
            let folder = try sharedFolderManager.addFolder(at: url)
            selectedSharedFolderID = folder.id
            showConfirmation(for: folder)
        } catch { show(error) }
    }

    func removeSharedFolder(id: UUID) {
        do {
            try sharedFolderManager.removeFolder(id: id)
            recentFileSystemEvents.removeAll { $0.sharedFolderID == id }
            if selectedSharedFolderID == id { selectedSharedFolderID = sharedFolders.first?.id }
        } catch { show(error) }
    }

    func setMonitoringEnabled(_ isEnabled: Bool, for id: UUID) {
        do { try sharedFolderManager.setEnabled(isEnabled, for: id) }
        catch { show(error) }
    }

    func revealSharedFolder(_ folder: SharedFolder) {
        NSWorkspace.shared.activateFileViewerSelecting([folder.rootURL])
    }

    func clearActivity(for sharedFolderID: UUID) {
        recentFileSystemEvents.removeAll { $0.sharedFolderID == sharedFolderID }
    }

    func clearSynchronizationActivity() { synchronizationActivity.removeAll() }

    func activity(for sharedFolderID: UUID) -> [FileChangeEvent] {
        recentFileSystemEvents.filter { $0.sharedFolderID == sharedFolderID }
    }

    func startListening() {
        activateDebugModeIfNeeded()
        guard let port = validatedPort(debugListeningPort, name: "listening port") else { return }
        if port != peerIdentity.listeningPort {
            peerIdentity.listeningPort = port
            rebuildCoordinator(identity: peerIdentity)
        }
        syncCoordinator.startListening()
    }

    func connect() {
        activateDebugModeIfNeeded()
        guard !debugRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show(DebugUIError.missingHost)
            return
        }
        guard let port = validatedPort(debugRemotePort, name: "peer port") else { return }
        syncCoordinator.connect(host: debugRemoteHost, port: port)
    }

    func disconnect() { syncCoordinator.disconnect() }
    func runInitialSync() { syncCoordinator.runInitialSync() }

    func shutdown() {
        commandPollingTask?.cancel()
        commandPollingTask = nil
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        pairingCoordinator?.shutdown()
        pairingCoordinator = nil
        syncCoordinator.stop()
        sharedFolderManager.stopAll()
        hasLaunched = false
        isSynchronizationPaused = false
    }

    func flushCriticalPersistence() {
        publishFinderSnapshot()
        if let recoveryRepository { Task { try? await recoveryRepository.flush() } }
    }

    func prepareForTermination() async {
        publishFinderSnapshot()
        if let recoveryRepository { try? await recoveryRepository.flush() }
        shutdown()
    }

    func pauseAllSynchronization() {
        guard !isSynchronizationPaused else { return }
        isSynchronizationPaused = true
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        pairingCoordinator?.shutdown()
        pairingCoordinator = nil
        syncCoordinator.stop()
        sharedFolderManager.stopAll()
        publishFinderSnapshot()
    }

    func resumeAllSynchronization() {
        guard isSynchronizationPaused else { return }
        isSynchronizationPaused = false
        sharedFolderManager.restore()
        sharedFolders = sharedFolderManager.sharedFolders
        Task { @MainActor [weak self] in await self?.startLocalNetworkServices() }
        Task { @MainActor [weak self] in await self?.runStartupRecovery() }
        publishFinderSnapshot()
    }

    func suspendForSystemSleep() {
        flushCriticalPersistence()
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        syncCoordinator.disconnect()
    }

    func resumeAfterSystemWake(servicesEnabled: Bool) {
        guard servicesEnabled, !isSynchronizationPaused else { return }
        localNetworkState = .reconnecting
        Task { @MainActor [weak self] in await self?.restartLocalNetworkServices() }
    }

    func handleNetworkChange(_ state: LocalNetworkState, interfaceChanged: Bool) {
        localNetworkState = state
        switch state {
        case .unavailable:
            bonjourBrowser?.stop()
            bonjourBrowser = nil
            syncCoordinator.disconnect()
        case .available where interfaceChanged || bonjourBrowser == nil:
            localNetworkState = .reconnecting
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                await self?.restartLocalNetworkServices()
            }
        case .available:
            attemptAutomaticConnection()
        case .reconnecting:
            break
        }
        publishFinderSnapshot()
    }

    func setAllSynchronizationPaused(_ paused: Bool) {
        paused ? pauseAllSynchronization() : resumeAllSynchronization()
    }

    func select(folderID: UUID) {
        isRecoveryCenterSelected = false
        selectedSharedFolderID = folderID
        selectedTrustedPeerID = nil
        selectedNearbyPeerID = nil
    }

    func select(trustedPeerID: UUID) {
        isRecoveryCenterSelected = false
        selectedTrustedPeerID = trustedPeerID
        selectedNearbyPeerID = nil
        selectedSharedFolderID = nil
    }

    func select(nearbyPeerID: String) {
        isRecoveryCenterSelected = false
        selectedNearbyPeerID = nearbyPeerID
        selectedTrustedPeerID = nil
        selectedSharedFolderID = nil
    }

    func selectRecoveryCenter() {
        isRecoveryCenterSelected = true
        selectedSharedFolderID = nil
        selectedTrustedPeerID = nil
        selectedNearbyPeerID = nil
        Task { await refreshRecoverySnapshot() }
    }

    func cancelReconciliation() { syncCoordinator.cancelReconciliation() }
    func retryReconciliation() { syncCoordinator.retryReconciliation() }

    func retryJournalOperation(_ operation: JournaledSyncOperation) {
        guard let recoveryRepository else { return }
        Task { @MainActor [weak self] in
            do {
                try await recoveryRepository.transition(operationID: operation.id, to: .retryScheduled)
                self?.syncCoordinator.retryReconciliation()
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func cancelJournalOperation(_ operation: JournaledSyncOperation) {
        guard !operation.isDestructive,
              [.queued, .waitingForPeer, .retryScheduled].contains(operation.state),
              let recoveryRepository else { return }
        Task { @MainActor [weak self] in
            do {
                try await recoveryRepository.transition(operationID: operation.id, to: .cancelled)
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func revealJournalOperation(_ operation: JournaledSyncOperation) {
        guard let folder = sharedFolders.first(where: { $0.id == operation.sharedFolderID }),
              let url = try? SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: operation.relativeSourcePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func resolveConflict(_ conflict: ConflictRecord, as resolution: ConflictResolutionState) {
        syncCoordinator.resolveConflict(conflict, as: resolution)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.refreshRecoverySnapshot()
        }
    }

    func revealConflict(_ conflict: ConflictRecord) {
        guard let mapping = shareMappings.first(where: { $0.id == conflict.mappingID }),
              let folder = sharedFolders.first(where: { $0.id == mapping.localSharedFolderID }) else { return }
        let paths = ([conflict.relativePath] + conflict.generatedConflictCopyPaths).compactMap {
            try? SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: $0)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths) }
    }

    func restoreTrashRecord(_ record: TrashRecord) {
        guard let recoveryRepository,
              let folder = sharedFolders.first(where: { $0.id == record.originalSharedFolderID }) else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await PeerNestTrashManager(repository: recoveryRepository).restore(record, to: folder.rootURL)
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func permanentlyDeleteTrashRecord(_ record: TrashRecord) {
        guard let recoveryRepository else { return }
        Task { @MainActor [weak self] in
            do {
                try await PeerNestTrashManager(repository: recoveryRepository).permanentlyDelete(record, confirmed: true)
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func restoreVersion(_ version: StoredFileVersion) {
        guard let recoveryRepository,
              let folder = sharedFolders.first(where: { $0.id == version.sharedFolderID }),
              let destination = try? SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: version.relativePath) else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await VersionHistoryStore(repository: recoveryRepository).restore(version, to: destination)
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func revealStoredVersion(_ version: StoredFileVersion) {
        guard let recoveryRepository else { return }
        Task { @MainActor in
            if let url = try? await recoveryRepository.storedURL(for: version.contentStorageRelativePath) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func exportStoredVersion(_ version: StoredFileVersion) {
        guard let recoveryRepository else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: version.relativePath).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor [weak self] in
            do {
                let source = try await recoveryRepository.storedURL(for: version.contentStorageRelativePath)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch { self?.show(error) }
        }
    }

    func updateRetentionPolicy(_ update: (inout RetentionPolicy) -> Void) {
        guard let recoveryRepository else { return }
        update(&retentionPolicy)
        let policy = retentionPolicy
        Task { try? await recoveryRepository.setRetentionPolicy(policy) }
    }

    func cleanupRecoveryStorage() {
        guard let recoveryRepository else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await RecoveryStorageManager(repository: recoveryRepository).cleanup()
                await self?.refreshRecoverySnapshot()
            } catch { self?.show(error) }
        }
    }

    func pair(with peer: DiscoveredPeer) {
        guard !isDebugModeActive else {
            show(SecureSessionError.plaintextForbidden)
            return
        }
        pairingCoordinator?.startPairing(with: peer)
        copyPairingState()
    }

    func pairNewIdentity(for peer: TrustedPeer) {
        guard peer.trustState == .identityChanged, let discovered = discoveredPeer(for: peer) else {
            show(PeerNestLANError.peerUnavailable)
            return
        }
        pairingCoordinator?.startPairing(with: discovered, replacingChangedIdentity: true)
        copyPairingState()
    }

    func approveIncomingPairing() { pairingCoordinator?.approveIncomingRequest() }
    func confirmPairingCode() { pairingCoordinator?.confirmCodesMatch() }
    func rejectPairing() { pairingCoordinator?.reject() }
    func cancelPairing() { pairingCoordinator?.cancel() }

    func isOnline(_ peer: TrustedPeer) -> Bool {
        discoveredPeer(for: peer)?.availability == .available
    }

    func isConnected(_ peer: TrustedPeer) -> Bool {
        connectedPeer?.peerID == peer.peerID && handshakeState == .ready
    }

    func connect(to peer: TrustedPeer) {
        manuallyPausedPeerIDs.remove(peer.peerID)
        guard let discovered = discoveredPeer(for: peer), discovered.availability == .available else {
            show(PeerNestLANError.peerUnavailable)
            return
        }
        syncCoordinator.connect(endpoint: discovered.endpoint, trustedPeer: peer)
    }

    func disconnect(from peer: TrustedPeer) {
        manuallyPausedPeerIDs.insert(peer.peerID)
        if connectedPeer?.peerID == peer.peerID { syncCoordinator.disconnect() }
    }

    func setAutoConnect(_ enabled: Bool, for peerID: UUID) {
        do {
            try trustedPeerStore.setAutoConnect(enabled, peerID: peerID)
            refreshTrustedPeers()
        } catch { show(error) }
    }

    func forget(peer: TrustedPeer) {
        do {
            if connectedPeer?.peerID == peer.peerID { syncCoordinator.disconnect() }
            try shareMappingStore.disableMappings(for: peer.peerID)
            try trustedPeerStore.forget(peerID: peer.peerID)
            shareMappings = shareMappingStore.mappings
            refreshTrustedPeers()
            selectedTrustedPeerID = nil
        } catch { show(error) }
    }

    func sendInvitation(folderID: UUID, to peerID: UUID, accessMode: SharedFolderAccessMode) {
        guard let folder = sharedFolders.first(where: { $0.id == folderID }),
              let peer = trustedPeers.first(where: { $0.peerID == peerID }) else {
            show(PeerNestLANError.peerUnavailable)
            return
        }
        let invitation = ShareInvitation(
            senderPeerID: peerIdentity.id,
            recipientPeerID: peer.peerID,
            senderSharedFolderID: folder.id,
            displayName: folder.displayName,
            accessMode: accessMode
        )
        syncCoordinator.sendInvitation(invitation, to: peer)
    }

    func acceptIncomingInvitation() async {
        guard let invitation = incomingInvitation,
              let selectedURL = await folderSelectionService.selectFolder() else { return }
        do {
            let destination: SharedFolder
            if let existing = sharedFolderManager.folder(matchingRootURL: selectedURL) {
                destination = existing
            } else {
                destination = try sharedFolderManager.addFolder(at: selectedURL)
            }
            try ShareInvitationPolicy.validateAcceptance(
                invitation,
                localDestinationID: destination.id,
                existingMappings: shareMappings
            )
            syncCoordinator.respondToInvitation(invitation, destinationFolderID: destination.id, accept: true)
            incomingInvitation = nil
        } catch { show(error) }
    }

    func rejectIncomingInvitation() {
        guard let invitation = incomingInvitation else { return }
        syncCoordinator.respondToInvitation(invitation, destinationFolderID: nil, accept: false)
        incomingInvitation = nil
    }

    func setMappingEnabled(_ enabled: Bool, mappingID: UUID) {
        guard var mapping = shareMappings.first(where: { $0.id == mappingID }) else { return }
        mapping.isEnabled = enabled
        do {
            try shareMappingStore.save(mapping)
            shareMappings = shareMappingStore.mappings
            if syncCoordinator.mapping?.id == mapping.id { syncCoordinator.restore(mapping: mapping) }
        } catch { show(error) }
    }

    func stopSynchronization(mappingID: UUID) {
        do {
            try shareMappingStore.stop(mappingID: mappingID)
            shareMappings = shareMappingStore.mappings
            if syncCoordinator.mapping?.id == mappingID { syncCoordinator.stopSynchronization() }
        } catch { show(error) }
    }

    func runInitialSync(mappingID: UUID) {
        guard let mapping = shareMappings.first(where: { $0.id == mappingID && $0.isEnabled }) else { return }
        syncCoordinator.restore(mapping: mapping)
        syncCoordinator.runInitialSync()
    }

    private func configureManager() {
        sharedFolderManager.onFoldersChanged = { [weak self] folders in
            guard let self else { return }
            sharedFolders = folders
            if let selectedSharedFolderID,
               !folders.contains(where: { $0.id == selectedSharedFolderID }) {
                self.selectedSharedFolderID = folders.first?.id
            }
            publishFinderSnapshot()
        }
        sharedFolderManager.onEvents = { [weak self] events in
            guard let self else { return }
            record(events)
            syncCoordinator.handleLocalEvents(events)
        }
        sharedFolderManager.onError = { [weak self] error in self?.show(error) }
    }

    private func startLocalNetworkServices() async {
        guard hasLaunched, !isDebugModeActive, !isSynchronizationPaused else { return }
        do {
            let cryptographicIdentity = try await deviceIdentityStore.identity()
            guard hasLaunched, !isDebugModeActive else { return }
            localSecurityFingerprint = cryptographicIdentity.fingerprint
            rebuildCoordinator(identity: peerIdentity, cryptographicIdentity: cryptographicIdentity)
            configurePairing(cryptographicIdentity: cryptographicIdentity)

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let advertisement = BonjourAdvertiser.advertisement(
                identity: peerIdentity,
                appVersion: appVersion,
                allowsPairing: true
            )
            advertisedServiceName = advertisement.serviceName
            syncCoordinator.transport.onListenerReady = { [weak self] port in
                self?.activeListenerPort = port
            }
            syncCoordinator.startListening(service: advertisement.service)

            let browser = BonjourBrowser(localPeerID: peerIdentity.id) { [weak self] record in
                guard let self else { return .available }
                guard let discoveryID = record.metadata.discoveryID,
                      let known = trustedPeerStore.peers.first(where: {
                          PeerFingerprintFormatter.shortDiscoveryID(peerID: $0.peerID) == discoveryID
                      }) else {
                    return record.metadata.allowsPairing ? .available : .unavailable
                }
                switch known.trustState {
                case .trusted: return .trusted
                case .identityChanged: return .identityChanged
                case .revoked, .unpaired, .pairingPending:
                    return record.metadata.allowsPairing ? .available : .unavailable
                }
            }
            browser.onPeersChanged = { [weak self] peers in
                guard let self else { return }
                nearbyPeers = peers
                attemptAutomaticConnection()
            }
            browser.onError = { [weak self] error in self?.show(error) }
            bonjourBrowser = browser
            browser.start()
        } catch { show(error) }
    }

    private func restartLocalNetworkServices() async {
        guard hasLaunched, !isSynchronizationPaused, !isDebugModeActive else { return }
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        pairingCoordinator?.shutdown()
        pairingCoordinator = nil
        syncCoordinator.stop()
        await startLocalNetworkServices()
        localNetworkState = .available
    }

    private func configurePairing(cryptographicIdentity: DeviceCryptographicIdentity) {
        let coordinator = PairingCoordinator(
            localIdentity: peerIdentity,
            cryptographicIdentity: cryptographicIdentity,
            trustedPeerStore: trustedPeerStore,
            transport: syncCoordinator.transport
        )
        coordinator.onStateChanged = { [weak self] in self?.copyPairingState() }
        coordinator.onTrustChanged = { [weak self] in self?.refreshTrustedPeers() }
        coordinator.onPaired = { [weak self] peer in
            guard let self else { return }
            refreshTrustedPeers()
            selectedTrustedPeerID = peer.peerID
            selectedNearbyPeerID = nil
            if AutoConnectPolicy.ownsPrimaryConnection(localPeerID: peerIdentity.id, remotePeerID: peer.peerID),
               let discovered = discoveredPeer(for: peer) {
                syncCoordinator.connect(endpoint: discovered.endpoint, trustedPeer: peer)
            }
        }
        coordinator.onError = { [weak self] error in self?.show(error) }
        pairingCoordinator = coordinator
        copyPairingState()
    }

    private func copyPairingState() {
        let hadIncomingRequest = incomingPairingRequest != nil
        guard let pairingCoordinator else {
            pairingState = .idle
            pairingPeerDisplayName = nil
            pairingActivities = []
            incomingPairingRequest = nil
            return
        }
        pairingState = pairingCoordinator.state
        pairingPeerDisplayName = pairingCoordinator.peerDisplayName
        pairingActivities = pairingCoordinator.activities
        incomingPairingRequest = pairingCoordinator.incomingRequest
        if !hadIncomingRequest, incomingPairingRequest != nil {
            onMainWindowRequested?()
        }
    }

    private func attemptAutomaticConnection() {
        guard !isDebugModeActive,
              connectionState != .connected,
              connectionState != .connecting,
              case .idle = pairingState else { return }
        for peer in trustedPeers where AutoConnectPolicy.shouldAutoConnect(
            localPeerID: peerIdentity.id,
            trustedPeer: peer,
            isAvailable: discoveredPeer(for: peer)?.availability == .available,
            isManuallyPaused: manuallyPausedPeerIDs.contains(peer.peerID)
        ) {
            if let discovered = discoveredPeer(for: peer) {
                syncCoordinator.connect(endpoint: discovered.endpoint, trustedPeer: peer)
                return
            }
        }
    }

    private func discoveredPeer(for trustedPeer: TrustedPeer) -> DiscoveredPeer? {
        let discoveryID = PeerFingerprintFormatter.shortDiscoveryID(peerID: trustedPeer.peerID)
        return nearbyPeers.first { $0.discoveryID == discoveryID }
    }

    private func refreshTrustedPeers() {
        trustedPeers = trustedPeerStore.peers
        nearbyPeers = nearbyPeers.map { discovered in
            var updated = discovered
            if let discoveryID = discovered.discoveryID,
               let peer = trustedPeers.first(where: {
                   PeerFingerprintFormatter.shortDiscoveryID(peerID: $0.peerID) == discoveryID
               }) {
                switch peer.trustState {
                case .trusted: updated.pairingStatus = .trusted
                case .identityChanged: updated.pairingStatus = .identityChanged
                case .revoked, .unpaired, .pairingPending: updated.pairingStatus = .available
                }
            }
            return updated
        }
    }

    private func activateDebugModeIfNeeded() {
        #if DEBUG
        guard !isDebugModeActive else { return }
        isDebugModeActive = true
        bonjourBrowser?.stop()
        bonjourBrowser = nil
        pairingCoordinator?.shutdown()
        pairingCoordinator = nil
        nearbyPeers = []
        advertisedServiceName = nil
        activeListenerPort = nil
        rebuildCoordinator(identity: peerIdentity)
        #endif
    }

    #if DEBUG
    private func startDebugIntegrationHarness() async {
        guard debugConfiguration.testNamespace != nil else { return }
        activateDebugModeIfNeeded()
        guard let listeningPort = debugConfiguration.listeningPort else {
            show(DebugUIError.invalidPort("listening port"))
            return
        }
        if peerIdentity.listeningPort != listeningPort {
            peerIdentity.listeningPort = listeningPort
            rebuildCoordinator(identity: peerIdentity)
        }
        PeerNestLog.security.warning("Starting explicitly insecure DEBUG localhost integration mode")
        syncCoordinator.startListening()

        guard debugConfiguration.integrationAutoConnect,
              let host = debugConfiguration.peerHost,
              let port = debugConfiguration.peerPort else { return }
        try? await Task.sleep(for: .milliseconds(750))
        guard hasLaunched else { return }
        syncCoordinator.connect(host: host, port: port)
    }
    #endif

    private func rebuildCoordinator(identity: PeerIdentity) {
        syncCoordinator?.stop()
        syncCoordinator = PeerSyncCoordinator(
            identity: identity,
            manager: sharedFolderManager,
            recoveryRepository: recoveryRepository,
            mappingProvider: { [weak self] folderID in
                self?.shareMappings.first { $0.localSharedFolderID == folderID && $0.isEnabled }
            }
        )
        configureCoordinatorCallbacks()
    }

    private func rebuildCoordinator(
        identity: PeerIdentity,
        cryptographicIdentity: DeviceCryptographicIdentity
    ) {
        syncCoordinator?.stop()
        syncCoordinator = PeerSyncCoordinator(
            identity: identity,
            manager: sharedFolderManager,
            cryptographicIdentity: cryptographicIdentity,
            trustedPeerProvider: { [weak self] peerID in self?.trustedPeerStore.peer(id: peerID) },
            identityChangedHandler: { [weak self] peerID, presentedKey in
                guard let self else { return }
                _ = try? trustedPeerStore.validate(peerID: peerID, publicIdentityKey: presentedKey)
                refreshTrustedPeers()
            },
            recoveryRepository: recoveryRepository,
            mappingProvider: { [weak self] folderID in
                self?.shareMappings.first { $0.localSharedFolderID == folderID && $0.isEnabled }
            }
        )
        configureCoordinatorCallbacks()
    }

    private func configureCoordinatorCallbacks() {
        syncCoordinator.onStateChanged = { [weak self] in self?.copyCoordinatorState() }
        syncCoordinator.onActivity = { [weak self] activity in
            guard let self else { return }
            #if DEBUG
            if let namespace = debugConfiguration.testNamespace {
                PeerNestLog.synchronization.notice("[\(namespace, privacy: .public)] \(activity.message, privacy: .public)")
            }
            #endif
            synchronizationActivity.insert(activity, at: 0)
            if synchronizationActivity.count > 100 { synchronizationActivity.removeLast(synchronizationActivity.count - 100) }
            if activity.kind == .sent || activity.kind == .received {
                lastSuccessfulSync = activity.timestamp
            }
            publishFinderSnapshot()
        }
        syncCoordinator.onError = { [weak self] error in
            #if DEBUG
            if let namespace = self?.debugConfiguration.testNamespace {
                PeerNestLog.synchronization.error("[\(namespace, privacy: .public)] \(error.localizedDescription, privacy: .public)")
            }
            #endif
            self?.latestSynchronizationError = error.localizedDescription
            self?.show(error)
        }
        syncCoordinator.onInvitationReceived = { [weak self] invitation in
            self?.incomingInvitation = invitation
            self?.onMainWindowRequested?()
        }
        syncCoordinator.onInvitationResolved = { [weak self] invitationID, accepted in
            guard let self else { return }
            if incomingInvitation?.id == invitationID { incomingInvitation = nil }
            if !accepted { latestSynchronizationError = PeerNestLANError.invitationRejected.localizedDescription }
        }
        syncCoordinator.onMappingChanged = { [weak self] mapping in
            guard let self, let mapping else { return }
            do {
                try shareMappingStore.save(mapping)
                shareMappings = shareMappingStore.mappings
            } catch { show(error) }
        }
        copyCoordinatorState()
    }

    private func copyCoordinatorState() {
        connectionState = syncCoordinator.connectionState
        listeningState = syncCoordinator.listeningState
        handshakeState = syncCoordinator.handshakeState
        connectedPeer = syncCoordinator.remotePeer
        shareMapping = syncCoordinator.mapping
        initialSyncState = syncCoordinator.initialSyncState
        pendingOperationCount = syncCoordinator.pendingOperationCount
        transferProgress = syncCoordinator.transferProgress
        reconciliationProgress = syncCoordinator.reconciliationProgress
        syncHealth = syncCoordinator.syncHealth
        unresolvedConflictCount = syncHealth.unresolvedConflictCount
        syncStatus = handshakeState == .ready ? .connected : .notConnected
        #if DEBUG
        if let namespace = debugConfiguration.testNamespace {
            let peer = connectedPeer.map { String($0.peerID.uuidString.prefix(8)) } ?? "none"
            let mapping = shareMapping.map { String($0.id.uuidString.prefix(8)) } ?? "none"
            let connection = String(describing: connectionState)
            let handshake = String(describing: handshakeState)
            let state = "local=\(String(peerIdentity.id.uuidString.prefix(8))) remote=\(peer) connection=\(connection) handshake=\(handshake) mapping=\(mapping) pending=\(pendingOperationCount)"
            if state != lastDebugConnectionLog {
                lastDebugConnectionLog = state
                PeerNestLog.connection.notice("[\(namespace, privacy: .public)] \(state, privacy: .public)")
            }
            if debugConfiguration.integrationAutoStart,
               handshakeState == .ready,
               shareMapping?.isEnabled == true,
               initialSyncState == .idle,
               !debugInitialSyncStarted {
                let initialSyncKey = "integrationInitialSyncStarted.v1"
                let namespaceDefaults = DebugTestNamespace(name: namespace)?.defaults
                if namespaceDefaults?.bool(forKey: initialSyncKey) != true {
                    debugInitialSyncStarted = true
                    namespaceDefaults?.set(true, forKey: initialSyncKey)
                    syncCoordinator.runInitialSync()
                }
            }
        }
        #endif
        publishFinderSnapshot()
        if handshakeState == .ready, let connectedPeer,
           let trusted = trustedPeerStore.peer(id: connectedPeer.peerID), trusted.trustState == .trusted {
            do {
                try trustedPeerStore.markConnected(
                    peerID: connectedPeer.peerID,
                    serviceName: discoveredPeer(for: trusted)?.serviceName
                )
                refreshTrustedPeers()
                if let persisted = shareMappings.first(where: {
                    $0.remotePeerID == connectedPeer.peerID && $0.isEnabled
                }), syncCoordinator.mapping?.id != persisted.id {
                    syncCoordinator.restore(mapping: persisted)
                }
            } catch { show(error) }
        }
    }

    private func runStartupRecovery() async {
        guard let recoveryRepository else { return }
        do {
            let diagnostics = try await StartupRecoveryCoordinator(repository: recoveryRepository).audit()
            if let latest = diagnostics.last,
               latest.category == "metadata-corruption" || latest.category.hasPrefix("missing-") {
                latestSynchronizationError = "Recovery issue \(latest.id.uuidString): \(latest.message)"
            }
            await refreshRecoverySnapshot()
        } catch { show(error) }
    }

    private func refreshRecoverySnapshot() async {
        guard let recoveryRepository else { return }
        let snapshot = await recoveryRepository.snapshot()
        journalOperations = snapshot.journal.sorted { $0.createdAt > $1.createdAt }
        conflicts = snapshot.conflicts.sorted { $0.detectedAt > $1.detectedAt }
        trashRecords = snapshot.trash.sorted { $0.deletedAt > $1.deletedAt }
        storedVersions = snapshot.versions.sorted { $0.storedAt > $1.storedAt }
        retentionPolicy = snapshot.retentionPolicy
        pendingOperationCount = snapshot.journal.filter { !$0.state.isTerminal }.count
        syncHealth.pendingOperationCount = pendingOperationCount
        syncHealth.pendingUploadBytes = snapshot.journal.filter { !$0.state.isTerminal }
            .compactMap(\.contentMetadata?.size).reduce(0, +)
        syncHealth.unresolvedConflictCount = snapshot.conflicts.filter { $0.resolutionState == .unresolved }.count
        syncHealth.trashSize = snapshot.trash.reduce(0) { $0 + $1.size }
        var versionSizes: [String: Int64] = [:]
        for version in snapshot.versions { versionSizes[version.contentHash] = version.size }
        syncHealth.versionHistorySize = versionSizes.values.reduce(0, +)
        unresolvedConflictCount = syncHealth.unresolvedConflictCount
        if syncHealth.unresolvedConflictCount > 0 { syncHealth.state = .conflictsNeedAttention }
        else if pendingOperationCount > 0 && handshakeState != .ready { syncHealth.state = .offlineChangesPending }
        else if pendingOperationCount > 0 { syncHealth.state = .syncing }
        else { syncHealth.state = .upToDate }
    }

    private func registerDebugFolder(path: String) async {
        let requestedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard sharedFolderManager.folder(matchingRootURL: requestedURL) == nil else { return }
        do {
            let folder = try sharedFolderManager.addFolder(at: requestedURL)
            selectedSharedFolderID = folder.id
        } catch {
            guard let authorized = await folderSelectionService.selectFolder(startingAt: requestedURL) else {
                show(DebugUIError.debugFolderNeedsAuthorization(path))
                return
            }
            guard SharedPathValidator.isSameLocation(authorized, requestedURL) else {
                show(FinderCommandHandlingError.wrongFolderAuthorized)
                return
            }
            do {
                let folder = try sharedFolderManager.addFolder(at: authorized)
                selectedSharedFolderID = folder.id
            } catch { show(error) }
        }
    }

    private func validatedPort(_ value: String, name: String) -> UInt16? {
        guard let port = UInt16(value), port > 0 else {
            show(DebugUIError.invalidPort(name))
            return nil
        }
        return port
    }

    private func record(_ events: [FileChangeEvent]) {
        recentFileSystemEvents.insert(contentsOf: events.reversed(), at: 0)
        var countsByFolder: [UUID: Int] = [:]
        recentFileSystemEvents = recentFileSystemEvents.filter { event in
            let count = countsByFolder[event.sharedFolderID, default: 0]
            guard count < 50 else { return false }
            countsByFolder[event.sharedFolderID] = count + 1
            return true
        }
    }

    func processPendingFinderCommands() async {
        guard !isConsumingFinderCommands, let finderCommandQueue else { return }
        isConsumingFinderCommands = true
        defer { isConsumingFinderCommands = false }
        do {
            for command in try finderCommandQueue.pendingCommands() {
                await handle(command)
                try finderCommandQueue.markConsumed(command)
                lastFinderCommandReceived = Date()
            }
        } catch { show(error) }
    }

    private func handle(_ command: FinderCommand) async {
        bringMainWindowForward()
        switch command.type {
        case .shareFolder: await handleShareCommand(command)
        case .stopSharing:
            guard let folder = sharedFolderManager.folder(matchingRootURL: command.selectedURL) else {
                show(SharedFolderManager.ManagerError.folderNotFound); return
            }
            removeSharedFolder(id: folder.id)
        case .showInApp:
            guard let folder = sharedFolderManager.folder(containing: command.selectedURL) else {
                show(SharedFolderManager.ManagerError.folderNotFound); return
            }
            selectedSharedFolderID = folder.id
        case .pauseSync:
            guard let folder = sharedFolderManager.folder(matchingRootURL: command.selectedURL) else {
                show(SharedFolderManager.ManagerError.folderNotFound); return
            }
            setMonitoringEnabled(false, for: folder.id)
        case .resumeSync:
            guard let folder = sharedFolderManager.folder(matchingRootURL: command.selectedURL) else {
                show(SharedFolderManager.ManagerError.folderNotFound); return
            }
            setMonitoringEnabled(true, for: folder.id)
        case .viewSyncStatus:
            guard let folder = sharedFolderManager.folder(containing: command.selectedURL) else {
                show(SharedFolderManager.ManagerError.folderNotFound); return
            }
            selectedSharedFolderID = folder.id
        }
    }

    private func handleShareCommand(_ command: FinderCommand) async {
        do {
            try SharedFolderOverlapPolicy.validate(candidate: command.selectedURL, existingRoots: sharedFolders.map(\.rootURL))
            do {
                let folder = try sharedFolderManager.addFolder(at: command.selectedURL, suppliedBookmarkData: command.bookmarkData)
                selectedSharedFolderID = folder.id
                showConfirmation(for: folder)
                return
            } catch {
                guard let authorizedURL = await folderSelectionService.selectFolder(startingAt: command.selectedURL) else {
                    throw BookmarkStore.BookmarkError.accessDenied
                }
                guard SharedPathValidator.isSameLocation(authorizedURL, command.selectedURL) else {
                    throw FinderCommandHandlingError.wrongFolderAuthorized
                }
                let folder = try sharedFolderManager.addFolder(at: authorizedURL)
                selectedSharedFolderID = folder.id
                showConfirmation(for: folder)
            }
        } catch { show(error) }
    }

    private func publishFinderSnapshot() {
        let generatedAt = Date()
        let sharedState = FinderSharedStateSnapshot(
            generatedAt: generatedAt,
            folders: sharedFolders.map { folder in
                FinderSharedFolderRecord(
                    id: folder.id,
                    rootURL: folder.rootURL,
                    isEnabled: folder.isEnabled,
                    state: finderBadgeState(for: folder),
                    updatedAt: generatedAt
                )
            }
        )
        do {
            try finderSharedStateStore?.write(sharedState)
        } catch {
            PeerNestLog.finderExtension.error("Shared-state snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }

        guard let finderBadgeStore else { return }
        let folders = sharedFolders.map { folder in
            FinderFolderBadgeRecord(
                sharedFolderID: folder.id,
                state: finderBadgeState(for: folder),
                targetedRelativePaths: [:]
            )
        }
        do {
            let snapshot = FinderBadgeSnapshot(generatedAt: generatedAt, folders: folders)
            try finderBadgeStore.write(snapshot)
            lastBadgeSnapshotPublished = snapshot.generatedAt
        } catch {
            PeerNestLog.finderExtension.error("Badge snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finderBadgeState(for folder: SharedFolder) -> FinderBadgeState {
        guard folder.isEnabled, !isSynchronizationPaused else { return .paused }
        switch overallSyncState {
        case .upToDate: return .upToDate
        case .syncing, .reconciling: return .syncing
        case .offlineChangesPending: return .offlineChangesPending
        case .conflictsNeedAttention: return .conflict
        case .paused: return .paused
        case .error: return .error
        case .idle: return .unknown
        }
    }

    private func showConfirmation(for folder: SharedFolder) {
        let needsPairing = !trustedPeers.contains { $0.trustState == .trusted }
        let notice = PresentedNotice(
            title: needsPairing ? "Folder Ready" : "Shared Folder Added",
            message: needsPairing
                ? "\(folder.displayName) is ready. Pair a nearby Mac to start syncing."
                : "Everything inside \(folder.displayName) is now included in this share."
        )
        presentedNotice = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard self?.presentedNotice?.id == notice.id else { return }
            self?.presentedNotice = nil
        }
    }

    func dismissPresentedNotice() {
        presentedNotice = nil
    }

    private func bringMainWindowForward() {
        onMainWindowRequested?()
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        presentedAlert = PresentedAlert(title: "PeerNest Couldn’t Complete That Action", message: message)
        onMainWindowRequested?()
    }
}

private enum FinderCommandHandlingError: LocalizedError {
    case wrongFolderAuthorized
    var errorDescription: String? { "Select the same folder you chose in Finder so PeerNest can establish lasting access." }
}

private enum DebugUIError: LocalizedError {
    case invalidPort(String)
    case missingHost
    case debugFolderNeedsAuthorization(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(name): "Enter a valid \(name) from 1 through 65535."
        case .missingHost: "Enter a peer host before connecting."
        case let .debugFolderNeedsAuthorization(path): "PeerNest needs you to select \(path) once to grant sandbox access."
        }
    }
}
