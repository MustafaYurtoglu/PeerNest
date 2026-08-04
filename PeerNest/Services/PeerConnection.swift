//
//  PeerConnection.swift
//  PeerNest
//

import Foundation
import Network

enum PeerConnectionState: Equatable, Sendable {
    case setup
    case connecting
    case connected
    case disconnected
    case failed(String)
    case reconnecting(attempt: Int)

    var title: String {
        switch self {
        case .setup: "Not started"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case let .failed(message): "Failed: \(message)"
        case let .reconnecting(attempt): "Reconnecting (attempt \(attempt))"
        }
    }
}

@MainActor
final class PeerConnection {
    let id = UUID()
    var onStateChanged: ((PeerConnectionState) -> Void)?
    var onMessage: ((PeerMessage) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let decoder = PeerFrameDecoder()
    private var isStopped = false

    init(connection: NWConnection, label: String = "PeerNest.PeerConnection") {
        self.connection = connection
        queue = DispatchQueue(label: label, qos: .utility)
    }

    convenience init(host: String, port: UInt16) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw DebugLaunchConfiguration.ConfigurationError.invalidPort("--peer-port", String(port))
        }
        self.init(connection: NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .tcp))
    }

    convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .tcp))
    }

    func start() {
        guard !isStopped else { return }
        onStateChanged?(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handle(state) }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func send(_ message: PeerMessage) async throws {
        let frame = try PeerFrameCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onStateChanged?(.disconnected)
        onStateChanged = nil
        onMessage = nil
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !isStopped else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try await decoder.append(data) {
                            onMessage?(message)
                        }
                    } catch {
                        onStateChanged?(.failed(error.localizedDescription))
                        stop()
                        return
                    }
                }
                if let error {
                    onStateChanged?(.failed(error.localizedDescription))
                    return
                }
                if isComplete {
                    onStateChanged?(.disconnected)
                    return
                }
                receiveNext()
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup: onStateChanged?(.setup)
        case .preparing, .waiting: onStateChanged?(.connecting)
        case .ready: onStateChanged?(.connected)
        case let .failed(error): onStateChanged?(.failed(error.localizedDescription))
        case .cancelled: onStateChanged?(.disconnected)
        @unknown default: onStateChanged?(.failed("Unknown Network.framework state"))
        }
    }
}
