//
//  PairingCoordinator.swift
//  PeerNest
//

import Foundation

@MainActor
final class PairingCoordinator {
    var onStateChanged: (() -> Void)?
    var onTrustChanged: (() -> Void)?
    var onPaired: ((TrustedPeer) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var state: PairingState = .idle
    private(set) var peerDisplayName: String?
    private(set) var incomingRequest: PairingHello?
    private(set) var activities: [PairingActivity] = []

    private let localIdentity: PeerIdentity
    private let cryptographicIdentity: DeviceCryptographicIdentity
    private let trustedPeerStore: TrustedPeerStore
    private let transport: PeerTransport
    private var session: PairingSession?
    private var targetPeer: DiscoveredPeer?
    private var expirationTask: Task<Void, Never>?
    private var recentAttempts: [Date] = []
    private var seenWireMessageIDs: Set<UUID> = []

    init(
        localIdentity: PeerIdentity,
        cryptographicIdentity: DeviceCryptographicIdentity,
        trustedPeerStore: TrustedPeerStore,
        transport: PeerTransport
    ) {
        self.localIdentity = localIdentity
        self.cryptographicIdentity = cryptographicIdentity
        self.trustedPeerStore = trustedPeerStore
        self.transport = transport
        transport.onPairingConnectionReady = { [weak self] in self?.sendInitialHello() }
        transport.onPairingMessage = { [weak self] message in self?.handle(message) }
    }

    func startPairing(
        with peer: DiscoveredPeer,
        replacingChangedIdentity: Bool = false,
        at now: Date = Date()
    ) {
        let permittedStatus = peer.pairingStatus == .available ||
            (replacingChangedIdentity && peer.pairingStatus == .identityChanged)
        guard peer.availability == .available, permittedStatus,
              peer.supportsCurrentProtocol else {
            report(PeerNestLANError.peerUnavailable)
            return
        }
        recentAttempts.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentAttempts.count < 5 else {
            report(PeerNestLANError.pairingRejected)
            return
        }
        recentAttempts.append(now)
        reset(keepConnection: true)
        targetPeer = peer
        peerDisplayName = peer.serviceName
        let newSession = PairingSession(
            localPeerID: localIdentity.id,
            localDisplayName: localIdentity.displayName,
            role: .initiator,
            identity: cryptographicIdentity,
            now: now
        )
        session = newSession
        state = .requesting
        record("Pairing requested with \(peer.serviceName).")
        scheduleExpiration()
        notify()
        transport.connectForPairing(endpoint: peer.endpoint)
    }

    func approveIncomingRequest() {
        guard let request = incomingRequest else { return }
        incomingRequest = nil
        peerDisplayName = request.displayName
        let newSession = PairingSession(
            localPeerID: localIdentity.id,
            localDisplayName: localIdentity.displayName,
            remotePeerID: request.peerID,
            role: .responder,
            identity: cryptographicIdentity,
            sessionID: request.sessionID,
            now: Date(),
            lifetime: max(1, request.expiresAt.timeIntervalSinceNow)
        )
        session = newSession
        scheduleExpiration(until: request.expiresAt)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await newSession.receive(request)
                let hello = try await newSession.hello()
                try await transport.sendPairing(.hello(hello))
                state = await newSession.state
                record("Pairing request approved. Compare the code on both Macs.")
                notify()
            } catch { report(error) }
        }
    }

    func confirmCodesMatch() {
        guard let session else { return }
        state = .confirming
        notify()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await session.confirmCodesMatch()
                try await transport.sendPairing(.confirmation(confirmation))
                state = await session.state
                record("Verification code confirmed on this Mac.")
                try await finishIfPossible()
                notify()
            } catch { report(error) }
        }
    }

    func reject() {
        let activeSession = session
        let request = incomingRequest
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let activeSession {
                let rejection = PairingRejection(
                    messageID: UUID(),
                    sessionID: activeSession.sessionID,
                    peerID: localIdentity.id
                )
                try? await transport.sendPairing(.rejection(rejection))
                await activeSession.reject()
            } else if let request {
                try? await transport.sendPairing(.rejection(PairingRejection(
                    messageID: UUID(),
                    sessionID: request.sessionID,
                    peerID: localIdentity.id
                )))
            }
            state = .rejected
            record("Pairing was rejected.")
            incomingRequest = nil
            expirationTask?.cancel()
            transport.disconnect()
            notify()
        }
    }

    func cancel() {
        reject()
        reset(keepConnection: false)
    }

    func shutdown() {
        expirationTask?.cancel()
        expirationTask = nil
        session = nil
        incomingRequest = nil
    }

    private func sendInitialHello() {
        guard let session else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await transport.sendPairing(.hello(try await session.hello())) }
            catch { report(error) }
        }
    }

    private func handle(_ message: PairingWireMessage) {
        let messageID: UUID
        switch message {
        case let .hello(value): messageID = value.messageID
        case let .confirmation(value): messageID = value.messageID
        case let .rejection(value): messageID = value.messageID
        }
        guard seenWireMessageIDs.insert(messageID).inserted else {
            report(PairingSessionError.replayedMessage)
            return
        }

        switch message {
        case let .hello(hello): handle(hello)
        case let .confirmation(confirmation): handle(confirmation)
        case .rejection:
            state = .rejected
            record("The other Mac rejected pairing.")
            transport.disconnect()
            notify()
        }
    }

    private func handle(_ hello: PairingHello) {
        guard hello.protocolVersion == PeerProtocolConstants.version else {
            report(PeerNestLANError.protocolMismatch)
            return
        }
        if let session, session.sessionID != hello.sessionID {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let preferred = PairingSession.preferredRole(
                    localPeerID: localIdentity.id,
                    remotePeerID: hello.peerID
                )
                if preferred == .initiator {
                    try? await transport.sendPairing(.rejection(PairingRejection(
                        messageID: UUID(),
                        sessionID: hello.sessionID,
                        peerID: localIdentity.id
                    )))
                    record("Simultaneous request resolved using this Mac’s pairing session.")
                } else {
                    await session.reject()
                    self.session = nil
                    incomingRequest = hello
                    record("Simultaneous request resolved using the other Mac’s pairing session.")
                    approveIncomingRequest()
                }
            }
            return
        }

        if let session {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await session.receive(hello)
                    state = await session.state
                    peerDisplayName = hello.displayName
                    record("Pairing response received. Compare the verification code.")
                    notify()
                } catch { report(error) }
            }
            return
        }

        let now = Date()
        recentAttempts.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentAttempts.count < 5 else {
            report(PeerNestLANError.pairingRejected)
            return
        }
        recentAttempts.append(now)
        guard hello.role == .initiator, hello.expiresAt > now else {
            report(PeerNestLANError.pairingExpired)
            return
        }
        incomingRequest = hello
        peerDisplayName = hello.displayName
        state = .awaitingRemoteApproval
        record("Incoming pairing request from \(hello.displayName).")
        scheduleExpiration(until: hello.expiresAt)
        notify()
    }

    private func handle(_ confirmation: PairingConfirmation) {
        guard let session else { report(PairingSessionError.invalidState); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await session.receive(confirmation)
                state = await session.state
                record("The other Mac confirmed the verification code.")
                try await finishIfPossible()
                notify()
            } catch { report(error) }
        }
    }

    private func finishIfPossible() async throws {
        guard let session, await session.state == .paired else { return }
        let peer = try await session.completedTrustedPeer(serviceName: targetPeer?.serviceName)
        try trustedPeerStore.save(peer)
        state = .paired
        record("\(peer.displayName) is now trusted.")
        expirationTask?.cancel()
        transport.disconnect()
        onTrustChanged?()
        onPaired?(peer)
    }

    private func scheduleExpiration(until date: Date = Date().addingTimeInterval(120)) {
        expirationTask?.cancel()
        expirationTask = Task { @MainActor [weak self] in
            let duration = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled, state != .paired else { return }
            state = .expired
            record("Pairing expired.")
            transport.disconnect()
            notify()
        }
    }

    private func reset(keepConnection: Bool) {
        expirationTask?.cancel()
        expirationTask = nil
        session = nil
        targetPeer = nil
        incomingRequest = nil
        peerDisplayName = nil
        state = .idle
        if !keepConnection { transport.disconnect() }
    }

    private func record(_ message: String) {
        activities.insert(PairingActivity(message: message), at: 0)
        if activities.count > 50 { activities.removeLast(activities.count - 50) }
    }

    private func report(_ error: Error) {
        state = error as? PairingSessionError == .expired ? .expired : .failed(error.localizedDescription)
        record(error.localizedDescription)
        onError?(error)
        notify()
    }

    private func notify() { onStateChanged?() }
}
