//
//  PeerServer.swift
//  PeerNest
//

import Foundation
import Network

@MainActor
final class PeerServer {
    enum ServerError: LocalizedError {
        case invalidPort(UInt16)

        var errorDescription: String? {
            switch self { case let .invalidPort(port): "Port \(port) is not a valid listening port." }
        }
    }

    var onConnection: ((NWConnection) -> Void)?
    var onStateChanged: ((PeerConnectionState) -> Void)?
    var onReady: ((UInt16) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "PeerNest.PeerServer", qos: .utility)

    func start(port: UInt16, service: NWListener.Service? = nil) throws {
        stop()
        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: .tcp)
        } else {
            guard let networkPort = NWEndpoint.Port(rawValue: port) else {
                throw ServerError.invalidPort(port)
            }
            listener = try NWListener(using: .tcp, on: networkPort)
        }
        listener.service = service
        self.listener = listener
        onStateChanged?(.connecting)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.handle(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.onConnection?(connection) }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .setup: onStateChanged?(.setup)
        case .waiting, .failed:
            if case let .failed(error) = state { onStateChanged?(.failed(error.localizedDescription)) }
            else { onStateChanged?(.connecting) }
        case .ready:
            onStateChanged?(.connected)
            if let port = listener?.port?.rawValue { onReady?(port) }
        case .cancelled: onStateChanged?(.disconnected)
        @unknown default: onStateChanged?(.failed("Unknown listener state"))
        }
    }
}
