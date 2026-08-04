import Foundation

@MainActor
final class ServiceContainer {
    let appState: AppState
    let preferences: PreferencesStore
    let lifecycle: AppLifecycleCoordinator
    let mainWindowCoordinator: MainWindowCoordinator
    let launchAtLogin: LaunchAtLoginManager
    private let powerCoordinator: SystemPowerCoordinator
    private let networkCoordinator: NetworkPathCoordinator
    private var hasStarted = false

    init() {
        let state = AppState()
        #if DEBUG
        let configuration = try? DebugLaunchConfiguration.parse(ProcessInfo.processInfo.arguments)
        let defaults = configuration?.testNamespace
            .flatMap(DebugTestNamespace.init(name:))?.defaults ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        #else
        let preferences = PreferencesStore()
        #endif
        appState = state
        self.preferences = preferences
        let mainWindowCoordinator = MainWindowCoordinator()
        self.mainWindowCoordinator = mainWindowCoordinator
        lifecycle = AppLifecycleCoordinator(
            appState: state,
            preferences: preferences,
            mainWindowCoordinator: mainWindowCoordinator
        )
        launchAtLogin = LaunchAtLoginManager()
        powerCoordinator = SystemPowerCoordinator(lifecycle: lifecycle)
        networkCoordinator = NetworkPathCoordinator { [weak state] networkState, interfaceChanged in
            state?.handleNetworkChange(networkState, interfaceChanged: interfaceChanged)
        }
        state.onMainWindowRequested = { [weak mainWindowCoordinator] in
            mainWindowCoordinator?.requestCriticalInteraction()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        mainWindowCoordinator.start()
        lifecycle.start()
        powerCoordinator.start()
        networkCoordinator.start()
    }

    func shutdown() async {
        guard hasStarted else { return }
        hasStarted = false
        networkCoordinator.stop()
        powerCoordinator.stop()
        await lifecycle.prepareForTermination()
        mainWindowCoordinator.stop()
    }
}
