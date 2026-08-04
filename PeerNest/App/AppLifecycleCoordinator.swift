import AppKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AppLifecycleCoordinator: NSObject {
    let appState: AppState
    let preferences: PreferencesStore
    let mainWindowCoordinator: MainWindowCoordinator
    private(set) var hasStarted = false
    private(set) var isShuttingDown = false

    init(
        appState: AppState,
        preferences: PreferencesStore,
        mainWindowCoordinator: MainWindowCoordinator
    ) {
        self.appState = appState
        self.preferences = preferences
        self.mainWindowCoordinator = mainWindowCoordinator
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        appState.launch(startServices: preferences.startServicesAutomatically)
        PeerNestLog.lifecycle.info("Application services started")
    }

    func showMainWindow(createWindow: () -> Void) {
        mainWindowCoordinator.showMainWindow(createWindow: createWindow)
    }

    func showSettings(openSettings: () -> Void) {
        mainWindowCoordinator.presentAuxiliaryWindow(openWindow: openSettings)
    }

    func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = NSImage(named: "PeerNestBrand") {
            options[.applicationIcon] = icon
        }
        mainWindowCoordinator.presentAuxiliaryWindow(
            openWindow: {
                NSApplication.shared.orderFrontStandardAboutPanel(options: options)
            },
            locateWindow: {
                NSApplication.shared.windows.first {
                    $0 is NSPanel && $0.title.localizedCaseInsensitiveContains("PeerNest")
                }
            }
        )
    }

    func pauseSynchronization() { appState.pauseAllSynchronization() }
    func resumeSynchronization() { appState.resumeAllSynchronization() }

    func prepareForTermination() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        await appState.prepareForTermination()
        PeerNestLog.lifecycle.info("Application services stopped")
    }
}
