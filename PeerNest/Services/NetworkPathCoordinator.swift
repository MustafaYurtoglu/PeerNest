import Foundation
import Network

final class NetworkPathCoordinator: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.mustafayurtoglu.PeerNest.path-monitor")
    private let handler: @MainActor (LocalNetworkState, Bool) -> Void
    private var previousInterfaces = Set<NWInterface.InterfaceType>()
    private var isStarted = false

    init(handler: @escaping @MainActor (LocalNetworkState, Bool) -> Void) {
        self.handler = handler
        monitor = NWPathMonitor()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = Set(path.availableInterfaces.map(\.type))
            let changed = !previousInterfaces.isEmpty && interfaces != previousInterfaces
            previousInterfaces = interfaces
            let state: LocalNetworkState = path.status == .satisfied ? .available : .unavailable
            Task { @MainActor in self.handler(state, changed) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }
}
