import AppKit
import Foundation

@MainActor
final class SystemPowerCoordinator: NSObject {
    private weak var lifecycle: AppLifecycleCoordinator?
    private var isObserving = false
    private var isSleeping = false
    private var wakeTask: Task<Void, Never>?

    init(lifecycle: AppLifecycleCoordinator) {
        self.lifecycle = lifecycle
        super.init()
    }

    func start() {
        guard !isObserving else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        isObserving = true
    }

    func stop() {
        wakeTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isObserving = false
    }

    @objc private func sleep() {
        guard !isSleeping else { return }
        isSleeping = true
        wakeTask?.cancel()
        lifecycle?.appState.suspendForSystemSleep()
    }

    @objc private func wake() {
        guard isSleeping else { return }
        isSleeping = false
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let lifecycle else { return }
            lifecycle.appState.resumeAfterSystemWake(servicesEnabled: lifecycle.preferences.startServicesAutomatically)
        }
    }
}
