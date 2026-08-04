//
//  PeerSyncCoordinator.swift
//  PeerNest
//

import Foundation
import Network

@MainActor
final class PeerSyncCoordinator {
    var onStateChanged: (() -> Void)?
    var onActivity: ((SyncActivity) -> Void)?
    var onError: ((Error) -> Void)?
    var onInvitationReceived: ((ShareInvitation) -> Void)?
    var onInvitationResolved: ((UUID, Bool) -> Void)?
    var onMappingChanged: ((ShareMapping?) -> Void)?

    private(set) var connectionState: PeerConnectionState = .setup
    private(set) var listeningState: PeerConnectionState = .setup
    private(set) var handshakeState: PeerHandshakeState = .idle
    private(set) var remotePeer: HelloPayload?
    private(set) var mapping: ShareMapping?
    private(set) var initialSyncState: InitialSyncState = .idle
    private(set) var pendingOperationCount = 0
    private(set) var transferProgress: Double?
    private(set) var reconciliationProgress = ReconciliationProgress()
    private(set) var syncHealth = SyncHealth()

    let identity: PeerIdentity
    let transport: PeerTransport

    private let manager: SharedFolderManager
    private let manifestBuilder = ManifestBuilder()
    private let registry = AppliedOperationRegistry()
    private let applier: RemoteOperationApplier
    private let receiver: FileTransferReceiver
    private let sender = FileTransferSender()
    private let recoveryRepository: RecoveryRepository?
    private let trashManager: PeerNestTrashManager?
    private let versionHistory: VersionHistoryStore?
    private let reconciliationCoordinator = ReconciliationCoordinator()
    private let mappingProvider: (UUID) -> ShareMapping?
    private var pendingOperations: [UUID: Date] = [:]
    private var operationRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var incomingTransfers: [UUID: (operationID: UUID, received: Int64, size: Int64)] = [:]
    private var pendingEventsByShare: [UUID: [String: FileChangeEvent]] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var messageProcessingTask: Task<Void, Never>?
    private let automaticallyOffersPrimaryShare: Bool
    private var outgoingInvitations: [UUID: ShareInvitation] = [:]
    private var incomingVersionsByOperation: [UUID: FileVersion] = [:]
    private var incomingDestinationOverrides: [UUID: String] = [:]
    private var transferResumeContinuations: [UUID: CheckedContinuation<FileTransferResumeResponsePayload, Error>] = [:]
    private var reconciliationTask: Task<Void, Never>?
    private var liveSyncIsPausedForReconciliation = false

    init(
        identity: PeerIdentity,
        manager: SharedFolderManager,
        recoveryRepository: RecoveryRepository? = nil,
        mappingProvider: @escaping (UUID) -> ShareMapping? = { _ in nil }
    ) {
        self.identity = identity
        self.manager = manager
        self.recoveryRepository = recoveryRepository
        self.mappingProvider = mappingProvider
        transport = PeerTransport(identity: identity)
        automaticallyOffersPrimaryShare = true
        applier = RemoteOperationApplier(registry: registry)
        receiver = FileTransferReceiver(registry: registry, repository: self.recoveryRepository)
        trashManager = self.recoveryRepository.map { PeerNestTrashManager(repository: $0) }
        versionHistory = self.recoveryRepository.map { VersionHistoryStore(repository: $0) }
        configureTransport()
    }

    init(
        identity: PeerIdentity,
        manager: SharedFolderManager,
        cryptographicIdentity: DeviceCryptographicIdentity,
        trustedPeerProvider: @escaping (UUID) -> TrustedPeer?,
        identityChangedHandler: @escaping (UUID, Data) -> Void = { _, _ in },
        recoveryRepository: RecoveryRepository? = nil,
        mappingProvider: @escaping (UUID) -> ShareMapping? = { _ in nil }
    ) {
        self.identity = identity
        self.manager = manager
        self.recoveryRepository = recoveryRepository
        self.mappingProvider = mappingProvider
        transport = PeerTransport(
            identity: identity,
            securityMode: .authenticated,
            cryptographicIdentity: cryptographicIdentity,
            trustedPeerProvider: trustedPeerProvider,
            identityChangedHandler: identityChangedHandler
        )
        automaticallyOffersPrimaryShare = false
        applier = RemoteOperationApplier(registry: registry)
        receiver = FileTransferReceiver(registry: registry, repository: self.recoveryRepository)
        trashManager = self.recoveryRepository.map { PeerNestTrashManager(repository: $0) }
        versionHistory = self.recoveryRepository.map { VersionHistoryStore(repository: $0) }
        configureTransport()
    }

    func startListening(service: NWListener.Service? = nil) {
        do {
            try transport.startListening(service: service)
            addActivity(identity.listeningPort == 0 ? "Starting local network listener." : "Listening on port \(identity.listeningPort).", .information)
        } catch { report(error) }
    }

    func connect(host: String, port: UInt16) {
        #if DEBUG
        transport.connect(host: host, port: port)
        #else
        report(SecureSessionError.plaintextForbidden)
        #endif
    }

    func connect(endpoint: NWEndpoint, trustedPeer: TrustedPeer) {
        transport.connect(endpoint: endpoint, trustedPeer: trustedPeer)
    }

    func disconnect() {
        transport.disconnect()
        initialSyncState = .idle
        pendingOperations.removeAll()
        operationRetryTasks.values.forEach { $0.cancel() }
        operationRetryTasks.removeAll()
        transferProgress = nil
        liveSyncIsPausedForReconciliation = true
        reconciliationTask?.cancel()
        reconciliationTask = nil
        Task {
            await receiver.suspendAll()
            await refreshRecoveryState()
        }
        notify()
    }

    func stop() {
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        messageProcessingTask?.cancel()
        messageProcessingTask = nil
        operationRetryTasks.values.forEach { $0.cancel() }
        operationRetryTasks.removeAll()
        transport.stop()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        Task {
            await receiver.suspendAll()
            try? await recoveryRepository?.flush()
        }
    }

    func runInitialSync() {
        guard handshakeState == .ready, let mapping,
              let localFolder = manager.folder(id: mapping.localSharedFolderID) else {
            report(CoordinatorError.noMappedShare)
            return
        }
        initialSyncState = .buildingManifest
        notify()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try await manifestBuilder.build(rootURL: localFolder.rootURL, includeHashes: true)
                initialSyncState = .comparing
                notify()
                try await transport.send(.manifestRequest, payload: ManifestRequestPayload(
                    requesterSharedFolderID: mapping.localSharedFolderID,
                    requestedSharedFolderID: mapping.remoteSharedFolderID,
                    requesterEntries: manifest.entries
                ))
                addActivity("Initial manifest sent (\(manifest.entries.count) items).", .sent)
            } catch {
                initialSyncState = .failed
                report(error)
            }
        }
    }

    func sendInvitation(_ invitation: ShareInvitation, to trustedPeer: TrustedPeer) {
        do {
            try ShareInvitationPolicy.validateForSending(invitation, trustedPeer: trustedPeer)
            guard handshakeState == .ready, remotePeer?.peerID == trustedPeer.peerID else {
                throw PeerNestLANError.peerUnavailable
            }
            guard manager.folder(id: invitation.senderSharedFolderID) != nil else {
                throw CoordinatorError.noSharedFolder
            }
            outgoingInvitations[invitation.id] = invitation
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await transport.send(.shareInvitation, payload: invitation)
                    addActivity("Folder invitation sent to \(trustedPeer.displayName).", .sent)
                } catch { report(error) }
            }
        } catch { report(error) }
    }

    func respondToInvitation(_ invitation: ShareInvitation, destinationFolderID: UUID?, accept: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if accept {
                    guard invitation.senderPeerID == remotePeer?.peerID,
                          invitation.recipientPeerID == identity.id,
                          !invitation.isExpired() else {
                        throw PeerNestLANError.unauthorizedOperation
                    }
                    guard let destinationFolderID, manager.folder(id: destinationFolderID) != nil else {
                        throw CoordinatorError.noSharedFolder
                    }
                    let mapping = ShareMapping(
                        localSharedFolderID: destinationFolderID,
                        remoteSharedFolderID: invitation.senderSharedFolderID,
                        remotePeerID: invitation.senderPeerID,
                        accessMode: invitation.accessMode,
                        localRole: .receiver,
                        remoteDisplayName: invitation.displayName
                    )
                    try await transport.send(.shareInvitationResponse, payload: ShareInvitationResponse(
                        invitationID: invitation.id,
                        accepted: true,
                        receiverSharedFolderID: destinationFolderID,
                        accessMode: invitation.accessMode
                    ))
                    self.mapping = mapping
                    onMappingChanged?(mapping)
                    addActivity("Accepted \(invitation.displayName) from the peer.", .received)
                } else {
                    try await transport.send(.shareInvitationResponse, payload: ShareInvitationResponse(
                        invitationID: invitation.id,
                        accepted: false,
                        receiverSharedFolderID: nil,
                        accessMode: invitation.accessMode
                    ))
                    addActivity("Folder invitation rejected.", .information)
                }
                onInvitationResolved?(invitation.id, accept)
                notify()
            } catch { report(error) }
        }
    }

    func restore(mapping: ShareMapping?) {
        self.mapping = mapping
        notify()
        if handshakeState == .ready, mapping?.isEnabled == true { beginReconciliation() }
    }

    func cancelReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        Task { await reconciliationCoordinator.cancel() }
        reconciliationProgress.state = .paused
        liveSyncIsPausedForReconciliation = true
        updateSyncHealth()
        notify()
    }

    func retryReconciliation() { beginReconciliation() }

    func resolveConflict(_ conflict: ConflictRecord, as resolution: ConflictResolutionState) {
        Task { @MainActor [weak self] in
            guard let self, let mapping, let recoveryRepository,
                  conflict.mappingID == mapping.id,
                  let folder = manager.folder(id: mapping.localSharedFolderID) else { return }
            do {
                if resolution == .keptLocal || resolution == .keptRemote,
                   let copyPath = conflict.generatedConflictCopyPaths.first {
                    let remoteKeepsOriginal = conflict.remoteVersion.map {
                        ConflictCopyNamer.remoteKeepsOriginal(localPeerID: self.identity.id, remotePeerID: $0.originatingPeerID)
                    } ?? false
                    let desiredVersionIsInCopy = resolution == .keptRemote ? !remoteKeepsOriginal : remoteKeepsOriginal
                    if desiredVersionIsInCopy {
                        let original = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: conflict.relativePath)
                        let copy = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: copyPath)
                        guard FileManager.default.fileExists(atPath: copy.path) else {
                            throw CoordinatorError.conflictContentUnavailable
                        }
                        if FileManager.default.fileExists(atPath: original.path), let versionHistory {
                            _ = try await versionHistory.store(
                                fileURL: original,
                                sharedFolderID: folder.id,
                                relativePath: conflict.relativePath,
                                originatingPeerID: identity.id,
                                reason: .conflict
                            )
                        }
                        let temporary = original.deletingLastPathComponent()
                            .appendingPathComponent(".peernest-resolution-\(UUID().uuidString)")
                        try FileManager.default.copyItem(at: copy, to: temporary)
                        if FileManager.default.fileExists(atPath: original.path) {
                            _ = try FileManager.default.replaceItemAt(original, withItemAt: temporary)
                        } else {
                            try FileManager.default.moveItem(at: temporary, to: original)
                        }
                    }
                }
                try await recoveryRepository.resolveConflict(
                    id: conflict.id,
                    resolution: resolution,
                    copyPaths: conflict.generatedConflictCopyPaths
                )
                if handshakeState == .ready {
                    try await transport.send(.conflictResolution, payload: ConflictResolutionPayload(
                        conflictID: conflict.id,
                        mappingID: mapping.id,
                        resolution: resolution,
                        generatedCopyPaths: conflict.generatedConflictCopyPaths
                    ))
                }
                await refreshRecoveryState()
            } catch { report(error) }
        }
    }

    func stopSynchronization() {
        guard var mapping else { return }
        mapping.isEnabled = false
        self.mapping = mapping
        onMappingChanged?(mapping)
        notify()
    }

    func handleLocalEvents(_ events: [FileChangeEvent]) {
        for event in events where event.origin == .local {
            pendingEventsByShare[event.sharedFolderID, default: [:]][event.relativePath] = event
            debounceTasks[event.sharedFolderID]?.cancel()
            debounceTasks[event.sharedFolderID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                // Once processing begins, a later filesystem event must schedule a new
                // debounce task instead of cancelling in-flight hashing or transfer work.
                debounceTasks[event.sharedFolderID] = nil
                let pending = pendingEventsByShare.removeValue(forKey: event.sharedFolderID) ?? [:]
                for event in pending.values.sorted(by: { $0.timestamp < $1.timestamp }) {
                    await processLocalEvent(event)
                }
            }
        }
    }

    private func configureTransport() {
        transport.onConnectionStateChanged = { [weak self] state in
            self?.connectionState = state
            self?.notify()
        }
        transport.onListeningStateChanged = { [weak self] state in
            self?.listeningState = state
            self?.notify()
        }
        transport.onHandshakeStateChanged = { [weak self] state in
            self?.handshakeState = state
            self?.notify()
        }
        transport.onRemotePeerChanged = { [weak self] peer in
            self?.remotePeer = peer
            self?.notify()
        }
        transport.onReady = { [weak self] in
            guard let self else { return }
            if automaticallyOffersPrimaryShare,
               let remotePeer,
               AutoConnectPolicy.ownsPrimaryConnection(
                   localPeerID: identity.id,
                   remotePeerID: remotePeer.peerID
               ) {
                offerPrimaryShare()
            }
            else if mapping != nil { beginReconciliation() }
            else { notify() }
        }
        transport.onMessage = { [weak self] message in self?.handle(message) }
        transport.onError = { [weak self] error in self?.report(error) }
    }

    private func offerPrimaryShare() {
        guard let folder = manager.sharedFolders.first(where: \.isEnabled) else {
            report(CoordinatorError.noSharedFolder)
            return
        }
        Task { [weak self] in
            try? await self?.transport.send(.shareOffer, payload: ShareOfferPayload(
                sharedFolderID: folder.id,
                displayName: folder.displayName,
                accessMode: folder.accessMode
            ))
        }
    }

    private func handle(_ message: PeerMessage) {
        if Self.bypassesSerializedMessageProcessing(message.messageType) {
            do { try handleTransferResumeResponse(message) }
            catch { report(error) }
            return
        }
        let previousTask = messageProcessingTask
        messageProcessingTask = Task { @MainActor [weak self] in
            _ = await previousTask?.result
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                switch message.messageType {
                case .shareInvitation: try handleInvitation(message)
                case .shareInvitationResponse: try handleInvitationResponse(message)
                case .shareOffer:
                    guard automaticallyOffersPrimaryShare else { throw PeerNestLANError.unauthorizedOperation }
                    try await handleShareOffer(message)
                case .shareAccept:
                    guard automaticallyOffersPrimaryShare else { throw PeerNestLANError.unauthorizedOperation }
                    try handleShareAccept(message)
                case .manifestRequest: try await handleManifestRequest(message)
                case .manifestResponse: try handleManifestResponse(message)
                case .syncOperation: try await handleSyncOperation(message)
                case .fileTransferStart: try await handleTransferStart(message)
                case .fileChunk: try await handleFileChunk(message)
                case .fileTransferComplete: try await handleTransferComplete(message)
                case .fileTransferResumeResponse: break
                case .operationAck: try handleAcknowledgment(message)
                case .reconciliationSummary: try await handleReconciliationSummary(message)
                case .reconciliationComplete: try await handleReconciliationComplete(message)
                case .tombstone: try await handleTombstone(message)
                case .conflictResolution: try await handleConflictResolution(message)
                case .error: report(try message.decodePayload(PeerErrorPayload.self))
                default: break
                }
            } catch {
                report(error)
                try? await sendProtocolError(error)
            }
        }
    }

    static func bypassesSerializedMessageProcessing(_ type: PeerMessageType) -> Bool {
        type == .fileTransferResumeResponse
    }

    private func handleInvitation(_ message: PeerMessage) throws {
        let invitation = try message.decodePayload(ShareInvitation.self)
        guard let remotePeer,
              message.senderPeerID == remotePeer.peerID,
              invitation.senderPeerID == remotePeer.peerID,
              invitation.recipientPeerID == identity.id,
              invitation.state == .pending else {
            throw PeerNestLANError.unauthorizedOperation
        }
        guard !invitation.isExpired() else { throw PeerNestLANError.pairingExpired }
        onInvitationReceived?(invitation)
        addActivity("Folder invitation received from \(remotePeer.displayName).", .received)
    }

    private func handleInvitationResponse(_ message: PeerMessage) throws {
        let response = try message.decodePayload(ShareInvitationResponse.self)
        guard let invitation = outgoingInvitations.removeValue(forKey: response.invitationID),
              invitation.recipientPeerID == message.senderPeerID else {
            throw PeerNestLANError.unauthorizedOperation
        }
        guard response.accepted, let remoteFolderID = response.receiverSharedFolderID else {
            onInvitationResolved?(invitation.id, false)
            throw PeerNestLANError.invitationRejected
        }
        guard !invitation.isExpired() else { throw PeerNestLANError.invitationRejected }
        guard response.accessMode == invitation.accessMode else {
            throw PeerNestLANError.unauthorizedOperation
        }
        let newMapping = ShareMapping(
            localSharedFolderID: invitation.senderSharedFolderID,
            remoteSharedFolderID: remoteFolderID,
            remotePeerID: invitation.recipientPeerID,
            accessMode: response.accessMode,
            localRole: .owner,
            remoteDisplayName: invitation.displayName
        )
        mapping = newMapping
        onMappingChanged?(newMapping)
        onInvitationResolved?(invitation.id, true)
        addActivity("The peer accepted \(invitation.displayName).", .received)
        notify()
        beginReconciliation()
    }

    private func handleShareOffer(_ message: PeerMessage) async throws {
        let offer = try message.decodePayload(ShareOfferPayload.self)
        guard let local = manager.sharedFolders.first(where: \.isEnabled), let remotePeer else {
            throw CoordinatorError.noSharedFolder
        }
        let newMapping = Self.negotiatedMapping(
            existing: mappingProvider(local.id),
            localSharedFolderID: local.id,
            remoteSharedFolderID: offer.sharedFolderID,
            remotePeerID: remotePeer.peerID,
            accessMode: offer.accessMode,
            localRole: .receiver,
            remoteDisplayName: offer.displayName
        )
        mapping = newMapping
        onMappingChanged?(newMapping)
        try await transport.send(.shareAccept, payload: ShareAcceptPayload(
            offeredSharedFolderID: offer.sharedFolderID,
            acceptingSharedFolderID: local.id,
            accessMode: local.accessMode
        ))
        addActivity("Mapped \(local.displayName) to \(offer.displayName).", .information)
        notify()
        beginReconciliation()
    }

    private func handleShareAccept(_ message: PeerMessage) throws {
        let acceptance = try message.decodePayload(ShareAcceptPayload.self)
        guard let local = manager.folder(id: acceptance.offeredSharedFolderID), let remotePeer else {
            throw CoordinatorError.noSharedFolder
        }
        let newMapping = Self.negotiatedMapping(
            existing: mappingProvider(local.id),
            localSharedFolderID: local.id,
            remoteSharedFolderID: acceptance.acceptingSharedFolderID,
            remotePeerID: remotePeer.peerID,
            accessMode: acceptance.accessMode,
            localRole: .owner,
            remoteDisplayName: local.displayName
        )
        mapping = newMapping
        onMappingChanged?(newMapping)
        addActivity("Peer accepted shared folder \(local.displayName).", .received)
        notify()
        beginReconciliation()
    }

    static func negotiatedMapping(
        existing: ShareMapping?,
        localSharedFolderID: UUID,
        remoteSharedFolderID: UUID,
        remotePeerID: UUID,
        accessMode: SharedFolderAccessMode,
        localRole: ShareMapping.LocalRole,
        remoteDisplayName: String?
    ) -> ShareMapping {
        let reusableID: UUID?
        if let existing,
           existing.localSharedFolderID == localSharedFolderID,
           existing.remoteSharedFolderID == remoteSharedFolderID,
           existing.remotePeerID == remotePeerID {
            reusableID = existing.id
        } else {
            reusableID = nil
        }
        return ShareMapping(
            id: reusableID ?? UUID(),
            localSharedFolderID: localSharedFolderID,
            remoteSharedFolderID: remoteSharedFolderID,
            remotePeerID: remotePeerID,
            accessMode: accessMode,
            localRole: localRole,
            remoteDisplayName: remoteDisplayName
        )
    }

    private func handleManifestRequest(_ message: PeerMessage) async throws {
        let request = try message.decodePayload(ManifestRequestPayload.self)
        guard let mapping,
              request.requestedSharedFolderID == mapping.localSharedFolderID,
              request.requesterSharedFolderID == mapping.remoteSharedFolderID,
              let localFolder = manager.folder(id: mapping.localSharedFolderID) else {
            throw CoordinatorError.invalidMapping
        }
        initialSyncState = .buildingManifest
        notify()
        let localManifest = try await manifestBuilder.build(rootURL: localFolder.rootURL, includeHashes: true)
        try await transport.send(.manifestResponse, payload: ManifestResponsePayload(
            sourceSharedFolderID: mapping.localSharedFolderID,
            destinationSharedFolderID: mapping.remoteSharedFolderID,
            entries: localManifest.entries
        ))
        let plan = try SyncPlanner.planConservativeInitialPush(
            source: localManifest.entries,
            destination: request.requesterEntries,
            sourceSharedFolderID: mapping.localSharedFolderID,
            sourcePeerName: identity.displayName
        )
        initialSyncState = .synchronizing
        notify()
        for conflict in plan.conflicts { addActivity("Preserving conflict as \(conflict).", .conflict) }
        if ShareAccessPolicy.permitsOutgoingMutation(mapping) {
            for operation in plan.operations {
                try await send(operation: operation, localFolder: localFolder, remoteFolderID: mapping.remoteSharedFolderID)
            }
        }
        initialSyncState = .completed
        addActivity("Initial synchronization push completed.", .information)
        notify()
    }

    private func handleManifestResponse(_ message: PeerMessage) throws {
        let response = try message.decodePayload(ManifestResponsePayload.self)
        guard let mapping,
              response.sourceSharedFolderID == mapping.remoteSharedFolderID,
              response.destinationSharedFolderID == mapping.localSharedFolderID else {
            throw CoordinatorError.invalidMapping
        }
        initialSyncState = .synchronizing
        addActivity("Received peer manifest (\(response.entries.count) items).", .received)
        notify()
    }

    private func handleSyncOperation(_ message: PeerMessage) async throws {
        let payload = try message.decodePayload(NetworkSyncOperationPayload.self)
        do {
            guard let mapping,
                  payload.destinationSharedFolderID == mapping.localSharedFolderID,
                  payload.operation.sharedFolderID == mapping.remoteSharedFolderID,
                  let folder = manager.folder(id: mapping.localSharedFolderID) else {
                throw CoordinatorError.invalidMapping
            }
            try ShareAccessPolicy.authorizeIncoming(
                payload.operation,
                destinationSharedFolderID: payload.destinationSharedFolderID,
                mapping: mapping
            )
            if let remoteSequence = payload.logicalSequence, let recoveryRepository {
                _ = try await recoveryRepository.nextLogicalClock(afterRemote: remoteSequence)
            }
            let resolution = try await prepareIncomingOperation(payload, mapping: mapping, folder: folder)
            if resolution == .duplicate {
                try await sendAck(payload.operation.id, state: .completed)
                return
            }
            if resolution == .preservedWithoutApply {
                try await sendAck(payload.operation.id, state: .completed)
                return
            }
            if payload.operation.type == .createFile || payload.operation.type == .updateFile {
                if let sourceVersion = payload.sourceVersion {
                    incomingVersionsByOperation[payload.operation.id] = sourceVersion
                }
                try await sendAck(payload.operation.id, state: .inProgress)
                return
            }
            if payload.operation.type == .delete {
                try await applyRecoverableDelete(payload, mapping: mapping, folder: folder)
                try await sendAck(payload.operation.id, state: .completed)
                addActivity("Moved remote deletion to PeerNest Trash: \(payload.operation.relativePath)", .received)
                return
            }
            _ = try await applier.apply(payload, rootURL: folder.rootURL)
            if let sourceVersion = payload.sourceVersion, let recoveryRepository {
                try await recoveryRepository.saveCurrentVersion(sourceVersion, mappingID: mapping.id)
            }
            try await sendAck(payload.operation.id, state: .completed)
            addActivity("Applied remote \(payload.operation.type.rawValue): \(payload.operation.relativePath)", .received)
        } catch {
            try? await sendAck(payload.operation.id, state: .failed, message: error.localizedDescription)
            throw error
        }
    }

    private func handleTransferStart(_ message: PeerMessage) async throws {
        let originalPayload = try message.decodePayload(FileTransferStartPayload.self)
        guard let mapping,
              originalPayload.destinationSharedFolderID == mapping.localSharedFolderID,
              originalPayload.sourceSharedFolderID == mapping.remoteSharedFolderID,
              let folder = manager.folder(id: mapping.localSharedFolderID) else {
            throw CoordinatorError.invalidMapping
        }
        guard ShareAccessPolicy.permitsIncomingMutation(mapping) else {
            throw PeerNestLANError.unauthorizedOperation
        }
        let destinationPath = incomingDestinationOverrides[originalPayload.operationID]
            ?? originalPayload.destinationRelativePath
        let payload = FileTransferStartPayload(
            transferID: originalPayload.transferID,
            operationID: originalPayload.operationID,
            sourceSharedFolderID: originalPayload.sourceSharedFolderID,
            destinationSharedFolderID: originalPayload.destinationSharedFolderID,
            sourceRelativePath: originalPayload.sourceRelativePath,
            destinationRelativePath: destinationPath,
            size: originalPayload.size,
            sha256: originalPayload.sha256,
            modificationDate: originalPayload.modificationDate,
            mappingID: originalPayload.mappingID,
            chunkSize: originalPayload.chunkSize,
            resumeToken: originalPayload.resumeToken
        )
        let destination = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: destinationPath)
        if FileManager.default.fileExists(atPath: destination.path), let versionHistory {
            _ = try? await versionHistory.store(
                fileURL: destination,
                sharedFolderID: folder.id,
                relativePath: destinationPath,
                originatingPeerID: identity.id,
                reason: .remoteUpdate
            )
        }
        let resume = try await receiver.start(payload, rootURL: folder.rootURL)
        incomingTransfers[payload.transferID] = (payload.operationID, 0, payload.size)
        transferProgress = payload.size == 0 ? 1 : 0
        try await sendAck(payload.operationID, state: .inProgress)
        if remotePeer?.capabilities.contains(.resumableTransfer) == true {
            try await transport.send(.fileTransferResumeResponse, payload: resume)
        }
        notify()
    }

    private func handleFileChunk(_ message: PeerMessage) async throws {
        let chunk = try message.decodePayload(FileChunkPayload.self)
        try await receiver.append(chunk)
        if var progress = incomingTransfers[chunk.transferID] {
            progress.received += Int64(chunk.data.count)
            incomingTransfers[chunk.transferID] = progress
            transferProgress = progress.size == 0 ? 1 : min(Double(progress.received) / Double(progress.size), 1)
            notify()
        }
    }

    private func handleTransferComplete(_ message: PeerMessage) async throws {
        let complete = try message.decodePayload(FileTransferCompletePayload.self)
        let operationID = incomingTransfers[complete.transferID]?.operationID
        do {
            let result = try await receiver.complete(transferID: complete.transferID)
            incomingTransfers[complete.transferID] = nil
            transferProgress = nil
            try await sendAck(result.operationID, state: .completed)
            if let version = incomingVersionsByOperation.removeValue(forKey: result.operationID),
               let mapping, let recoveryRepository {
                let appliedVersion = FileVersion(
                    versionID: version.versionID,
                    relativePath: result.destinationRelativePath,
                    itemType: version.itemType,
                    size: version.size,
                    modificationDate: version.modificationDate,
                    contentHash: version.contentHash,
                    originatingPeerID: version.originatingPeerID,
                    logicalSequence: version.logicalSequence,
                    parentVersionID: version.parentVersionID,
                    createdAt: version.createdAt
                )
                try await recoveryRepository.saveCurrentVersion(appliedVersion, mappingID: mapping.id)
            }
            incomingDestinationOverrides[result.operationID] = nil
            addActivity("Received file: \(result.destinationRelativePath)", .received)
            notify()
        } catch {
            incomingTransfers[complete.transferID] = nil
            transferProgress = nil
            if let operationID { try? await sendAck(operationID, state: .failed, message: error.localizedDescription) }
            throw error
        }
    }

    private func handleAcknowledgment(_ message: PeerMessage) throws {
        let ack = try message.decodePayload(OperationAckPayload.self)
        if ack.state == .completed || ack.state == .failed {
            pendingOperations[ack.operationID] = nil
            operationRetryTasks.removeValue(forKey: ack.operationID)?.cancel()
            pendingOperationCount = pendingOperations.count
            if let recoveryRepository {
                Task { @MainActor [weak self] in
                    guard let self, let journaled = await recoveryRepository.operation(id: ack.operationID) else { return }
                    do {
                        if ack.state == .completed {
                            try await recoveryRepository.transition(operationID: ack.operationID, to: .completed)
                            try await recoveryRepository.acknowledge(
                                operationID: ack.operationID,
                                logicalSequence: journaled.logicalSequence,
                                mappingID: journaled.mappingID
                            )
                        } else {
                            try await recoveryRepository.transition(
                                operationID: ack.operationID,
                                to: .permanentlyFailed,
                                errorCategory: .protocolFailure
                            )
                        }
                        await refreshRecoveryState()
                    } catch { report(error) }
                }
            }
            notify()
        }
        if ack.state == .failed { throw CoordinatorError.remoteFailure(ack.message ?? "Unknown failure") }
    }

    private func processLocalEvent(_ event: FileChangeEvent) async {
        guard let eventMapping = mappingForLocalShare(event.sharedFolderID),
              eventMapping.isEnabled,
              let folder = manager.folder(id: event.sharedFolderID) else { return }
        do {
            var currentHash: String?
            if !event.isDirectory, FileManager.default.fileExists(atPath: event.localURL.path) {
                try await waitForStableFile(event.localURL)
                currentHash = try await FileHashing.sha256(of: event.localURL)
            }
            if await registry.shouldSuppress(
                sharedFolderID: event.sharedFolderID,
                relativePath: event.relativePath,
                resultingHash: currentHash
            ) { return }

            let type: SyncOperation.OperationType
            switch event.type {
            case .folderCreated: type = .createDirectory
            case .folderRemoved, .fileRemoved: type = .delete
            case .fileCreated: type = .createFile
            case .fileModified: type = .updateFile
            case .itemRenamed:
                if FileManager.default.fileExists(atPath: event.localURL.path) {
                    type = event.isDirectory ? .createDirectory : .updateFile
                } else { type = .delete }
            }
            let operation = try SyncOperation(
                sharedFolderID: event.sharedFolderID,
                type: type,
                relativePath: event.relativePath
            )
            try ShareAccessPolicy.authorizeOutgoing(operation, mapping: eventMapping)
            guard let recoveryRepository else {
                if handshakeState == .ready, mapping?.id == eventMapping.id {
                    try await send(operation: operation, localFolder: folder, remoteFolderID: eventMapping.remoteSharedFolderID)
                }
                return
            }
            let logicalSequence = try await recoveryRepository.nextLogicalClock()
            let parentVersion = await recoveryRepository.currentVersion(
                mappingID: eventMapping.id,
                relativePath: event.relativePath
            )
            var contentMetadata: JournalContentMetadata?
            if !event.isDirectory, FileManager.default.fileExists(atPath: event.localURL.path), let versionHistory {
                let stored = try await versionHistory.store(
                    fileURL: event.localURL,
                    sharedFolderID: event.sharedFolderID,
                    relativePath: event.relativePath,
                    originatingPeerID: identity.id,
                    reason: .localUpdate
                )
                contentMetadata = JournalContentMetadata(
                    size: stored.size,
                    contentHash: stored.contentHash,
                    modificationDate: event.timestamp,
                    stagingRelativePath: stored.contentStorageRelativePath
                )
                let version = FileVersion(
                    versionID: UUID(),
                    relativePath: event.relativePath,
                    itemType: .file,
                    size: stored.size,
                    modificationDate: event.timestamp,
                    contentHash: stored.contentHash,
                    originatingPeerID: identity.id,
                    logicalSequence: logicalSequence,
                    parentVersionID: parentVersion?.versionID,
                    createdAt: Date()
                )
                try await recoveryRepository.saveCurrentVersion(version, mappingID: eventMapping.id)
            } else if event.isDirectory, operation.type != .delete {
                let version = FileVersion(
                    versionID: UUID(),
                    relativePath: event.relativePath,
                    itemType: .directory,
                    size: 0,
                    modificationDate: event.timestamp,
                    contentHash: nil,
                    originatingPeerID: identity.id,
                    logicalSequence: logicalSequence,
                    parentVersionID: parentVersion?.versionID,
                    createdAt: Date()
                )
                try await recoveryRepository.saveCurrentVersion(version, mappingID: eventMapping.id)
            }
            if operation.type == .delete {
                let policy = await recoveryRepository.retentionPolicy()
                let expiration = Date().addingTimeInterval(TimeInterval(policy.trashRetentionDays * 86_400))
                try await recoveryRepository.addTombstone(Tombstone(
                    tombstoneID: UUID(),
                    sharedFolderID: event.sharedFolderID,
                    mappingID: eventMapping.id,
                    relativePath: event.relativePath,
                    deletedVersionID: parentVersion?.versionID,
                    deletingPeerID: identity.id,
                    deletedAt: Date(),
                    logicalClock: logicalSequence,
                    expirationDate: expiration,
                    restoreState: .active,
                    acknowledgedPeerIDs: [identity.id]
                ))
            }
            let journaled = JournaledSyncOperation(
                operation: operation,
                mappingID: eventMapping.id,
                originPeerID: identity.id,
                destinationPeerID: eventMapping.remotePeerID,
                expectedSourceVersion: parentVersion?.versionID,
                expectedDestinationVersion: parentVersion?.versionID,
                contentMetadata: contentMetadata,
                state: handshakeState == .ready && mapping?.id == eventMapping.id && !liveSyncIsPausedForReconciliation
                    ? .queued : .waitingForPeer,
                logicalSequence: logicalSequence
            )
            try await recoveryRepository.enqueue(journaled)
            await refreshRecoveryState()
            if handshakeState == .ready, mapping?.id == eventMapping.id, !liveSyncIsPausedForReconciliation {
                try await send(journaled: journaled, localFolder: folder, remoteFolderID: eventMapping.remoteSharedFolderID)
            } else {
                addActivity("Queued offline change: \(event.relativePath)", .information)
            }
        } catch { report(error) }
    }

    private func mappingForLocalShare(_ sharedFolderID: UUID) -> ShareMapping? {
        if let mapping, mapping.localSharedFolderID == sharedFolderID { return mapping }
        return mappingProvider(sharedFolderID)
    }

    private func send(operation: SyncOperation, localFolder: SharedFolder, remoteFolderID: UUID) async throws {
        guard let mapping else { throw CoordinatorError.invalidMapping }
        try ShareAccessPolicy.authorizeOutgoing(operation, mapping: mapping)
        guard remoteFolderID == mapping.remoteSharedFolderID else { throw CoordinatorError.invalidMapping }
        pendingOperations[operation.id] = Date()
        if pendingOperations.count > 1_000,
           let oldest = pendingOperations.min(by: { $0.value < $1.value })?.key {
            pendingOperations[oldest] = nil
        }
        pendingOperationCount = pendingOperations.count
        notify()
        let payload = NetworkSyncOperationPayload(operation: operation, destinationSharedFolderID: remoteFolderID)
        try await retrying { try await self.transport.send(.syncOperation, payload: payload) }
        switch operation.type {
        case .createFile, .updateFile:
            let source = try SharedPathValidator.destinationURL(in: localFolder.rootURL, relativePath: operation.relativePath)
            try await sender.send(
                fileURL: source,
                operation: operation,
                destinationSharedFolderID: remoteFolderID,
                transport: transport,
                progress: { [weak self] value in self?.transferProgress = value; self?.notify() }
            )
            transferProgress = nil
            addActivity("Sent file: \(operation.relativePath)", .sent)
        default:
            addActivity("Sent \(operation.type.rawValue): \(operation.relativePath)", .sent)
        }
        scheduleAcknowledgmentRetry(
            operation: operation,
            localFolder: localFolder,
            remoteFolderID: remoteFolderID,
            nextAttempt: 2
        )
    }

    private func send(
        journaled: JournaledSyncOperation,
        localFolder: SharedFolder,
        remoteFolderID: UUID
    ) async throws {
        guard let recoveryRepository else {
            try await send(operation: journaled.syncOperation(), localFolder: localFolder, remoteFolderID: remoteFolderID)
            return
        }
        let operation = try journaled.syncOperation()
        do {
            try await recoveryRepository.transition(operationID: operation.id, to: .preparing)
            try await recoveryRepository.transition(operationID: operation.id, to: .sending)
            pendingOperations[operation.id] = Date()
            pendingOperationCount = pendingOperations.count
            let sourceVersion = await recoveryRepository.currentVersion(
                mappingID: journaled.mappingID,
                relativePath: operation.relativePath
            )
            let payload = NetworkSyncOperationPayload(
                operation: operation,
                destinationSharedFolderID: remoteFolderID,
                mappingID: journaled.mappingID,
                sourceVersion: sourceVersion,
                expectedDestinationVersionID: journaled.expectedDestinationVersion,
                logicalSequence: journaled.logicalSequence
            )
            try await retrying { try await self.transport.send(.syncOperation, payload: payload) }
            if operation.type == .createFile || operation.type == .updateFile {
                let source: URL
                if let storedPath = journaled.contentMetadata?.stagingRelativePath {
                    source = try await recoveryRepository.storedURL(for: storedPath)
                } else {
                    source = try SharedPathValidator.destinationURL(in: localFolder.rootURL, relativePath: operation.relativePath)
                }
                let supportsResume = remotePeer?.capabilities.contains(.resumableTransfer) == true
                let negotiator: ((FileTransferStartPayload) async throws -> FileTransferResumeResponsePayload)?
                if supportsResume {
                    negotiator = { [weak self] start in
                        guard let self else { throw CoordinatorError.sendFailed }
                        return try await self.negotiateResume(start)
                    }
                } else {
                    negotiator = nil
                }
                try await sender.send(
                    fileURL: source,
                    operation: operation,
                    destinationSharedFolderID: remoteFolderID,
                    transport: transport,
                    mappingID: journaled.mappingID,
                    negotiateResume: negotiator,
                    progress: { [weak self] value in self?.transferProgress = value; self?.notify() }
                )
            }
            try await recoveryRepository.transition(operationID: operation.id, to: .awaitingAcknowledgment)
            scheduleAcknowledgmentRetry(
                operation: operation,
                localFolder: localFolder,
                remoteFolderID: remoteFolderID,
                nextAttempt: 2
            )
            await refreshRecoveryState()
        } catch {
            try? await recoveryRepository.transition(
                operationID: operation.id,
                to: handshakeState == .ready ? .retryScheduled : .waitingForPeer,
                errorCategory: errorCategory(for: error),
                incrementRetry: true
            )
            await refreshRecoveryState()
            throw error
        }
    }

    private func scheduleAcknowledgmentRetry(
        operation: SyncOperation,
        localFolder: SharedFolder,
        remoteFolderID: UUID,
        nextAttempt: Int
    ) {
        operationRetryTasks[operation.id]?.cancel()
        operationRetryTasks[operation.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, pendingOperations[operation.id] != nil else { return }
            guard nextAttempt <= 3 else {
                pendingOperations[operation.id] = nil
                pendingOperationCount = pendingOperations.count
                operationRetryTasks[operation.id] = nil
                report(CoordinatorError.acknowledgmentTimeout(operation.id))
                return
            }
            do {
                if let recoveryRepository,
                   let journaled = await recoveryRepository.operation(id: operation.id) {
                    try? await recoveryRepository.transition(
                        operationID: operation.id,
                        to: .retryScheduled,
                        errorCategory: .connectivity,
                        incrementRetry: true
                    )
                    try await send(journaled: journaled, localFolder: localFolder, remoteFolderID: remoteFolderID)
                    return
                }
                let payload = NetworkSyncOperationPayload(operation: operation, destinationSharedFolderID: remoteFolderID)
                try await retrying { try await self.transport.send(.syncOperation, payload: payload) }
                if operation.type == .createFile || operation.type == .updateFile {
                    let source = try SharedPathValidator.destinationURL(
                        in: localFolder.rootURL,
                        relativePath: operation.relativePath
                    )
                    try await sender.send(
                        fileURL: source,
                        operation: operation,
                        destinationSharedFolderID: remoteFolderID,
                        transport: transport,
                        progress: { [weak self] value in self?.transferProgress = value; self?.notify() }
                    )
                    transferProgress = nil
                }
                scheduleAcknowledgmentRetry(
                    operation: operation,
                    localFolder: localFolder,
                    remoteFolderID: remoteFolderID,
                    nextAttempt: nextAttempt + 1
                )
            } catch {
                report(error)
                scheduleAcknowledgmentRetry(
                    operation: operation,
                    localFolder: localFolder,
                    remoteFolderID: remoteFolderID,
                    nextAttempt: nextAttempt + 1
                )
            }
        }
    }

    private enum IncomingPreparation {
        case applyNormally
        case duplicate
        case preservedWithoutApply
    }

    private func prepareIncomingOperation(
        _ payload: NetworkSyncOperationPayload,
        mapping: ShareMapping,
        folder: SharedFolder
    ) async throws -> IncomingPreparation {
        guard let recoveryRepository else { return .applyNormally }
        let checkpoint = await recoveryRepository.checkpoint(mappingID: mapping.id)
        if checkpoint.acknowledgedOperationIDs.contains(payload.operation.id) { return .duplicate }
        guard let remoteVersion = payload.sourceVersion else { return .applyNormally }
        let localVersion = await recoveryRepository.currentVersion(
            mappingID: mapping.id,
            relativePath: payload.operation.relativePath
        )
        let conflictType = Self.incomingConflictType(
            operationType: payload.operation.type,
            localVersion: localVersion,
            remoteVersion: remoteVersion,
            expectedDestinationVersionID: payload.expectedDestinationVersionID
        )
        guard let conflictType else { return .applyNormally }

        let conflictID = Self.stableConflictID(
            mappingID: mapping.id,
            path: payload.operation.relativePath,
            localVersionID: localVersion?.versionID,
            remoteVersionID: remoteVersion.versionID
        )
        if await recoveryRepository.conflicts().contains(where: { $0.conflictID == conflictID }) {
            return conflictType == .deleteVsModify ? .preservedWithoutApply : .applyNormally
        }
        var copyPaths: [String] = []
        if conflictType != .deleteVsModify {
            let occupied = Set((try? FileManager.default.contentsOfDirectory(
                at: folder.rootURL,
                includingPropertiesForKeys: nil
            ).compactMap { try? SharedPathValidator.safeRelativePath(from: folder.rootURL, to: $0) }) ?? [])
            let remoteKeepsOriginal = ConflictCopyNamer.remoteKeepsOriginal(
                localPeerID: identity.id,
                remotePeerID: remoteVersion.originatingPeerID
            ) && conflictType != .fileVsDirectory
            let copyPath = ConflictCopyNamer.path(
                originalPath: payload.operation.relativePath,
                losingPeerName: remoteKeepsOriginal ? identity.displayName : (remotePeer?.displayName ?? "Peer"),
                losingPeerID: remoteKeepsOriginal ? identity.id : remoteVersion.originatingPeerID,
                versionID: remoteKeepsOriginal ? (localVersion?.versionID ?? UUID()) : remoteVersion.versionID,
                occupiedPaths: occupied
            )
            copyPaths = [copyPath]
            if remoteKeepsOriginal {
                let original = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: payload.operation.relativePath)
                let copy = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: copyPath)
                if FileManager.default.fileExists(atPath: original.path), !FileManager.default.fileExists(atPath: copy.path) {
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: original, to: copy)
                }
            } else {
                incomingDestinationOverrides[payload.operation.id] = copyPath
            }
        }
        let baseVersion = payload.expectedDestinationVersionID.flatMap { id in
            localVersion?.versionID == id ? localVersion : nil
        }
        try await recoveryRepository.addConflict(ConflictRecord(
            conflictID: conflictID,
            mappingID: mapping.id,
            relativePath: payload.operation.relativePath,
            localVersion: localVersion,
            remoteVersion: remoteVersion,
            baseVersion: baseVersion,
            conflictType: conflictType,
            detectedAt: Date(),
            resolutionState: conflictType == .deleteVsModify ? .unresolved : .keepBoth,
            generatedConflictCopyPaths: copyPaths,
            userDecision: conflictType == .deleteVsModify ? nil : .keepBoth,
            diagnosticID: conflictID.uuidString
        ))
        addActivity("Conflict preserved for \(payload.operation.relativePath).", .conflict)
        await refreshRecoveryState()
        return conflictType == .deleteVsModify ? .preservedWithoutApply : .applyNormally
    }

    nonisolated static func incomingConflictType(
        operationType: SyncOperation.OperationType,
        localVersion: FileVersion?,
        remoteVersion: FileVersion,
        expectedDestinationVersionID: UUID?
    ) -> ConflictType? {
        guard let localVersion else { return nil }
        if let expectedDestinationVersionID {
            if localVersion.versionID == expectedDestinationVersionID { return nil }
            if operationType == .delete { return .deleteVsModify }
            return ConflictDetector.conflictType(
                local: localVersion,
                remote: remoteVersion,
                remoteOperation: operationType
            )
        }
        return ConflictDetector.conflictType(
            local: localVersion,
            remote: remoteVersion,
            remoteOperation: operationType
        )
    }

    private func applyRecoverableDelete(
        _ payload: NetworkSyncOperationPayload,
        mapping: ShareMapping,
        folder: SharedFolder
    ) async throws {
        try await applier.validateDeletion(relativePath: payload.operation.relativePath, rootURL: folder.rootURL)
        guard await registry.claimOperation(payload.operation.id) else { return }
        await registry.register(
            operationID: payload.operation.id,
            sharedFolderID: folder.id,
            relativePath: payload.operation.relativePath,
            expectedHash: nil
        )
        let destination = try SharedPathValidator.destinationURL(
            in: folder.rootURL,
            relativePath: payload.operation.relativePath
        )
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        if let trashManager, let recoveryRepository {
            let clock = try await recoveryRepository.nextLogicalClock(afterRemote: payload.logicalSequence)
            _ = try await trashManager.moveToTrash(
                sharedFolderID: folder.id,
                mappingID: mapping.id,
                rootURL: folder.rootURL,
                relativePath: payload.operation.relativePath,
                deletingPeerID: remotePeer?.peerID ?? mapping.remotePeerID,
                logicalClock: clock,
                deletedVersionID: payload.expectedDestinationVersionID
            )
        } else {
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func negotiateResume(_ start: FileTransferStartPayload) async throws -> FileTransferResumeResponsePayload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transferResumeContinuations[start.transferID] = continuation
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await transport.send(.fileTransferStart, payload: start)
                        try await Task.sleep(for: .seconds(10))
                        if let pending = transferResumeContinuations.removeValue(forKey: start.transferID) {
                            pending.resume(throwing: CoordinatorError.sendFailed)
                        }
                    } catch {
                        transferResumeContinuations.removeValue(forKey: start.transferID)?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.transferResumeContinuations.removeValue(forKey: start.transferID)?
                    .resume(throwing: CancellationError())
            }
        }
    }

    private func handleTransferResumeResponse(_ message: PeerMessage) throws {
        let response = try message.decodePayload(FileTransferResumeResponsePayload.self)
        transferResumeContinuations.removeValue(forKey: response.transferID)?.resume(returning: response)
    }

    private func beginReconciliation() {
        guard handshakeState == .ready, let mapping, mapping.isEnabled,
              let recoveryRepository else { return }
        reconciliationTask?.cancel()
        liveSyncIsPausedForReconciliation = true
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pending = await coalescedPendingOperations(
                    repository: recoveryRepository,
                    mappingID: mapping.id
                )
                await reconciliationCoordinator.begin(totalItems: pending.count)
                reconciliationProgress = await reconciliationCoordinator.progress
                updateSyncHealth()
                notify()
                let checkpoint = await recoveryRepository.checkpoint(mappingID: mapping.id)
                let summary = await reconciliationCoordinator.makeSummary(
                    mapping: mapping,
                    operations: pending,
                    tombstones: await recoveryRepository.tombstones(mappingID: mapping.id),
                    checkpoint: checkpoint,
                    logicalClock: await recoveryRepository.currentLogicalClock()
                )
                try await transport.send(.reconciliationSummary, payload: summary)
                addActivity("Exchanged offline synchronization checkpoint.", .information)
            } catch is CancellationError {
                await reconciliationCoordinator.cancel()
                reconciliationProgress = await reconciliationCoordinator.progress
                notify()
            } catch {
                await reconciliationCoordinator.fail(error)
                reconciliationProgress = await reconciliationCoordinator.progress
                report(error)
            }
        }
    }

    private func handleReconciliationSummary(_ message: PeerMessage) async throws {
        let summary = try message.decodePayload(ReconciliationSummaryPayload.self)
        guard let mapping,
              summary.sourceSharedFolderID == mapping.remoteSharedFolderID,
              summary.destinationSharedFolderID == mapping.localSharedFolderID,
              let repository = recoveryRepository else { throw CoordinatorError.invalidMapping }
        _ = try await repository.nextLogicalClock(afterRemote: summary.logicalClock)
        for tombstone in summary.tombstones {
            try await applyRemoteTombstone(tombstone, mapping: mapping)
        }
        try await reconciliationCoordinator.advance(
            state: .comparing,
            completed: 0,
            message: "Comparing queued operations"
        )
        reconciliationProgress = await reconciliationCoordinator.progress
        let pending = await coalescedPendingOperations(repository: repository, mappingID: mapping.id)
        let missing = await reconciliationCoordinator.operationsMissingFromRemote(
            local: pending,
            remoteSummary: summary
        )
        try await reconciliationCoordinator.advance(
            state: .transferring,
            completed: 0,
            message: "Replaying offline changes"
        )
        reconciliationProgress = await reconciliationCoordinator.progress
        if let folder = manager.folder(id: mapping.localSharedFolderID) {
            for (index, operation) in missing.enumerated() {
                try Task.checkCancellation()
                if operation.state == .awaitingAcknowledgment {
                    try? await repository.transition(operationID: operation.id, to: .retryScheduled)
                }
                try await send(journaled: await repository.operation(id: operation.id) ?? operation,
                               localFolder: folder,
                               remoteFolderID: mapping.remoteSharedFolderID)
                try await reconciliationCoordinator.advance(
                    state: .transferring,
                    completed: index + 1,
                    message: "Replayed \(index + 1) of \(missing.count) changes"
                )
                reconciliationProgress = await reconciliationCoordinator.progress
                notify()
            }
        }
        try await reconciliationCoordinator.advance(state: .verifying, completed: missing.count, message: "Verifying checkpoints")
        try await transport.send(.reconciliationComplete, payload: ReconciliationCompletePayload(
            sourceSharedFolderID: mapping.localSharedFolderID,
            destinationSharedFolderID: mapping.remoteSharedFolderID,
            mappingID: mapping.id,
            highestAppliedSequence: (await repository.checkpoint(mappingID: mapping.id)).highestContiguousSequence
        ))
        reconciliationProgress = await reconciliationCoordinator.progress
        notify()
    }

    private func handleReconciliationComplete(_ message: PeerMessage) async throws {
        let complete = try message.decodePayload(ReconciliationCompletePayload.self)
        guard let mapping,
              complete.sourceSharedFolderID == mapping.remoteSharedFolderID,
              complete.destinationSharedFolderID == mapping.localSharedFolderID else {
            throw CoordinatorError.invalidMapping
        }
        try await reconciliationCoordinator.complete()
        reconciliationProgress = await reconciliationCoordinator.progress
        liveSyncIsPausedForReconciliation = false
        syncHealth.lastSuccessfulSync = Date()
        addActivity("Offline reconciliation completed.", .information)
        await replayPendingOperations()
        updateSyncHealth()
        notify()
    }

    private func replayPendingOperations() async {
        guard handshakeState == .ready, let mapping,
              let folder = manager.folder(id: mapping.localSharedFolderID),
              let repository = recoveryRepository else { return }
        let pending = await coalescedPendingOperations(repository: repository, mappingID: mapping.id)
        for operation in pending where operation.state != .awaitingAcknowledgment {
            do { try await send(journaled: operation, localFolder: folder, remoteFolderID: mapping.remoteSharedFolderID) }
            catch { report(error); break }
        }
    }

    private func coalescedPendingOperations(
        repository: RecoveryRepository,
        mappingID: UUID
    ) async -> [JournaledSyncOperation] {
        let raw = await repository.pendingOperations(mappingID: mappingID)
        let coalesced = OperationDependencyResolver.ordered(OperationCoalescer.coalesce(raw))
        let retainedIDs = Set(coalesced.map(\.id))
        for operation in raw where !retainedIDs.contains(operation.id) {
            try? await repository.transition(operationID: operation.id, to: .cancelled)
        }
        return coalesced
    }

    private func applyRemoteTombstone(_ tombstone: Tombstone, mapping: ShareMapping) async throws {
        guard let repository = recoveryRepository else { return }
        if tombstone.sharedFolderID == mapping.localSharedFolderID {
            // The peer is echoing our tombstone with its acknowledgment set merged.
            try await repository.addTombstone(tombstone)
            return
        }
        guard tombstone.sharedFolderID == mapping.remoteSharedFolderID else { return }
        if await repository.tombstones(mappingID: mapping.id).contains(where: { $0.tombstoneID == tombstone.tombstoneID }) {
            try await repository.acknowledgeTombstone(id: tombstone.tombstoneID, peerID: identity.id)
            return
        }
        let localVersion = await repository.currentVersion(mappingID: mapping.id, relativePath: tombstone.relativePath)
        if let localVersion, localVersion.logicalSequence > tombstone.logicalClock {
            let conflictID = Self.stableConflictID(
                mappingID: mapping.id,
                path: tombstone.relativePath,
                localVersionID: localVersion.versionID,
                remoteVersionID: tombstone.deletedVersionID
            )
            try await repository.addConflict(ConflictRecord(
                conflictID: conflictID,
                mappingID: mapping.id,
                relativePath: tombstone.relativePath,
                localVersion: localVersion,
                remoteVersion: nil,
                baseVersion: nil,
                conflictType: .deleteVsModify,
                detectedAt: Date(),
                resolutionState: .unresolved,
                generatedConflictCopyPaths: [],
                userDecision: nil,
                diagnosticID: conflictID.uuidString
            ))
            try await repository.addTombstone(tombstone)
            return
        }
        if let folder = manager.folder(id: mapping.localSharedFolderID), let trashManager {
            let url = try SharedPathValidator.destinationURL(in: folder.rootURL, relativePath: tombstone.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                await registry.register(
                    operationID: tombstone.tombstoneID,
                    sharedFolderID: folder.id,
                    relativePath: tombstone.relativePath,
                    expectedHash: nil
                )
                _ = try await trashManager.moveToTrash(
                    sharedFolderID: folder.id,
                    mappingID: mapping.id,
                    rootURL: folder.rootURL,
                    relativePath: tombstone.relativePath,
                    deletingPeerID: tombstone.deletingPeerID,
                    logicalClock: tombstone.logicalClock,
                    deletedVersionID: tombstone.deletedVersionID
                )
            }
        }
        try await repository.addTombstone(tombstone)
        try await repository.acknowledgeTombstone(id: tombstone.tombstoneID, peerID: identity.id)
    }

    private func handleTombstone(_ message: PeerMessage) async throws {
        let payload = try message.decodePayload(TombstonePayload.self)
        guard let mapping,
              payload.sourceSharedFolderID == mapping.remoteSharedFolderID,
              payload.destinationSharedFolderID == mapping.localSharedFolderID else {
            throw CoordinatorError.invalidMapping
        }
        try await applyRemoteTombstone(payload.tombstone, mapping: mapping)
    }

    private func handleConflictResolution(_ message: PeerMessage) async throws {
        let payload = try message.decodePayload(ConflictResolutionPayload.self)
        guard let mapping, payload.mappingID == mapping.id || message.senderPeerID == mapping.remotePeerID else {
            throw CoordinatorError.invalidMapping
        }
        try await recoveryRepository?.resolveConflict(
            id: payload.conflictID,
            resolution: payload.resolution,
            copyPaths: payload.generatedCopyPaths
        )
        await refreshRecoveryState()
    }

    private func refreshRecoveryState() async {
        guard let recoveryRepository else { return }
        let snapshot = await recoveryRepository.snapshot()
        pendingOperationCount = snapshot.journal.filter { !$0.state.isTerminal }.count
        syncHealth.pendingOperationCount = pendingOperationCount
        syncHealth.pendingUploadBytes = snapshot.journal.filter { !$0.state.isTerminal }
            .compactMap(\.contentMetadata?.size).reduce(0, +)
        syncHealth.unresolvedConflictCount = snapshot.conflicts.filter { $0.resolutionState == .unresolved }.count
        syncHealth.trashSize = snapshot.trash.reduce(0) { $0 + $1.size }
        var versionSizes: [String: Int64] = [:]
        for version in snapshot.versions { versionSizes[version.contentHash] = version.size }
        syncHealth.versionHistorySize = versionSizes.values.reduce(0, +)
        updateSyncHealth()
        notify()
    }

    private func updateSyncHealth() {
        if syncHealth.latestError != nil { syncHealth.state = .error }
        else if reconciliationProgress.state == .failed { syncHealth.state = .error }
        else if reconciliationProgress.state == .paused { syncHealth.state = .paused }
        else if liveSyncIsPausedForReconciliation { syncHealth.state = .reconciling }
        else if syncHealth.unresolvedConflictCount > 0 { syncHealth.state = .conflictsNeedAttention }
        else if pendingOperationCount > 0 && handshakeState != .ready { syncHealth.state = .offlineChangesPending }
        else if pendingOperationCount > 0 { syncHealth.state = .syncing }
        else { syncHealth.state = .upToDate }
        syncHealth.reconciliationProgress = reconciliationProgress
    }

    private func errorCategory(for error: Error) -> JournalErrorCategory {
        if error is PeerNestLANError { return .connectivity }
        if error is FileTransferReceiver.TransferError { return .integrity }
        if error is SharedPathValidationError { return .sourceUnavailable }
        return .unknown
    }

    private nonisolated static func stableConflictID(
        mappingID: UUID,
        path: String,
        localVersionID: UUID?,
        remoteVersionID: UUID?
    ) -> UUID {
        let material = "\(mappingID.uuidString)|\(path)|\(localVersionID?.uuidString ?? "none")|\(remoteVersionID?.uuidString ?? "none")"
        let bytes = Array(material.utf8)
        var value = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() { value[index % 16] = value[index % 16] &+ byte }
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }

    private func retrying(_ action: () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do { try await action(); return }
            catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .milliseconds(250 * (1 << attempt))) }
            }
        }
        throw lastError ?? CoordinatorError.sendFailed
    }

    private func waitForStableFile(_ url: URL) async throws {
        var previous: (Int?, Date?)?
        for _ in 0..<5 {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let current = (values.fileSize, values.contentModificationDate)
            if let previous, previous.0 == current.0, previous.1 == current.1 { return }
            previous = current
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func sendAck(_ operationID: UUID, state: OperationAcknowledgmentState, message: String? = nil) async throws {
        try await transport.send(.operationAck, payload: OperationAckPayload(
            operationID: operationID,
            state: state,
            message: message
        ))
    }

    private func sendProtocolError(_ error: Error) async throws {
        try await transport.send(.error, payload: PeerErrorPayload(
            code: String(describing: type(of: error)),
            message: error.localizedDescription
        ))
    }

    private func addActivity(_ message: String, _ kind: SyncActivity.Kind) {
        onActivity?(SyncActivity(message: message, kind: kind))
    }

    private func report(_ error: Error) {
        addActivity(error.localizedDescription, .failure)
        onError?(error)
        notify()
    }

    private func notify() { onStateChanged?() }

    enum CoordinatorError: LocalizedError {
        case noSharedFolder, noMappedShare, invalidMapping, readOnlyShare, sendFailed, conflictContentUnavailable, acknowledgmentTimeout(UUID), remoteFailure(String)

        var errorDescription: String? {
            switch self {
            case .noSharedFolder: "Add and enable a shared folder before connecting."
            case .noMappedShare: "No shared folder is mapped to the connected peer."
            case .invalidMapping: "The peer referenced a share outside the accepted mapping."
            case .readOnlyShare: "The mapped shared folder does not allow remote writes."
            case .sendFailed: "The synchronization operation could not be sent."
            case .conflictContentUnavailable: "The preserved conflict copy is no longer available."
            case let .acknowledgmentTimeout(operationID): "Operation \(operationID.uuidString) was not acknowledged after three attempts."
            case let .remoteFailure(message): "The peer rejected an operation: \(message)"
            }
        }
    }
}

extension PeerErrorPayload: LocalizedError {
    nonisolated var errorDescription: String? { "Peer error [\(code)]: \(message)" }
}
