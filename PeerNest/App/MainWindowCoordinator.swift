import AppKit
import Foundation
import OSLog

@MainActor
protocol ApplicationActivationControlling: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

@MainActor
final class SystemApplicationActivationController: ApplicationActivationControlling {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        if NSApplication.shared.activationPolicy() == activationPolicy {
            return true
        }
        return NSApplication.shared.setActivationPolicy(activationPolicy)
    }

    func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MainWindowCoordinator: NSObject {
    enum MainWindowState: Equatable {
        case opening
        case visible
        case hidden
        case closed
    }

    enum WindowRole: Equatable {
        case primary
        case auxiliary
    }

    static let mainSceneID = "main"
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PeerNest.MainWindow")

    private(set) var mainWindowState: MainWindowState = .closed
    private(set) var observerRegistrationCount = 0

    private let activationController: ApplicationActivationControlling
    private let notificationCenter: NotificationCenter
    private weak var primaryWindow: NSWindow?
    private var rolesByWindowID: [ObjectIdentifier: WindowRole] = [:]
    private var visibleAuxiliaryWindowIDs: Set<ObjectIdentifier> = []
    private var syntheticVisibleAuxiliaryIDs: Set<UUID> = []
    private var isAuxiliaryPresentationPending = false
    private var isWindowCreationInFlight = false
    private var hasStarted = false
    private var appliedActivationPolicy: NSApplication.ActivationPolicy?

    init(
        activationController: ApplicationActivationControlling? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.activationController = activationController ?? SystemApplicationActivationController()
        self.notificationCenter = notificationCenter
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        registerObservers()
        setRegularActivation()
    }

    func stop() {
        guard hasStarted else { return }
        notificationCenter.removeObserver(self)
        hasStarted = false
        observerRegistrationCount = 0
        rolesByWindowID.removeAll()
        visibleAuxiliaryWindowIDs.removeAll()
        syntheticVisibleAuxiliaryIDs.removeAll()
        primaryWindow = nil
        isWindowCreationInFlight = false
        appliedActivationPolicy = nil
    }

    func register(_ window: NSWindow, role: WindowRole) {
        let id = ObjectIdentifier(window)
        if let existingRole = rolesByWindowID[id] {
            guard existingRole == role else { return }
            if window.isVisible {
                switch role {
                case .primary:
                    primaryWindowDidBecomeVisible()
                case .auxiliary:
                    visibleAuxiliaryWindowIDs.insert(id)
                    reconcileActivationPolicy()
                }
            }
            return
        }
        rolesByWindowID[id] = role

        switch role {
        case .primary:
            primaryWindow = window
            isWindowCreationInFlight = false
            window.identifier = Self.mainWindowIdentifier
            if window.isVisible {
                primaryWindowDidBecomeVisible()
            }
        case .auxiliary:
            isAuxiliaryPresentationPending = false
            if window.isVisible {
                visibleAuxiliaryWindowIDs.insert(id)
                reconcileActivationPolicy()
            }
        }
    }

    func showMainWindow(createWindow: () -> Void) {
        setRegularActivation()

        if let primaryWindow {
            if primaryWindow.isMiniaturized {
                primaryWindow.deminiaturize(nil)
            }
            primaryWindow.makeKeyAndOrderFront(nil)
            primaryWindowDidBecomeVisible()
        } else if !isWindowCreationInFlight {
            mainWindowState = .opening
            isWindowCreationInFlight = true
            createWindow()
            clearWindowCreationInFlightLater()
        }
        activationController.activate()
    }

    func requestMainWindow() {
        setRegularActivation()
        if primaryWindow == nil {
            mainWindowState = .opening
        }
        notificationCenter.post(name: .openPeerNestMainWindow, object: nil)
        activationController.activate()
    }

    func presentAuxiliaryWindow(
        openWindow: () -> Void,
        locateWindow: (() -> NSWindow?)? = nil
    ) {
        isAuxiliaryPresentationPending = true
        setRegularActivation()
        openWindow()
        activationController.activate()

        if let window = locateWindow?() {
            register(window, role: .auxiliary)
        } else if let locateWindow {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let window = locateWindow() else { return }
                register(window, role: .auxiliary)
            }
        }
        clearPendingAuxiliaryPresentationLater()
    }

    func requestCriticalInteraction() {
        requestMainWindow()
    }

    // These event methods are internal so policy transitions remain deterministic in unit tests.
    func primaryWindowDidBecomeVisible() {
        isWindowCreationInFlight = false
        mainWindowState = .visible
        PeerNestLog.lifecycle.info("Primary PeerNest window opened")
        setRegularActivation()
    }

    func primaryWindowDidBecomeHidden() {
        mainWindowState = .hidden
        reconcileActivationPolicy()
    }

    func primaryWindowDidClose() {
        isWindowCreationInFlight = false
        mainWindowState = .closed
        PeerNestLog.lifecycle.info("Primary PeerNest window closed")
        reconcileActivationPolicy()
    }

    func auxiliaryWindowDidBecomeVisible(testID: UUID) {
        syntheticVisibleAuxiliaryIDs.insert(testID)
        setRegularActivation()
    }

    func auxiliaryWindowDidClose(testID: UUID) {
        syntheticVisibleAuxiliaryIDs.remove(testID)
        reconcileActivationPolicy()
    }

    private func registerObservers() {
        let notifications: [(Notification.Name, Selector)] = [
            (NSWindow.didBecomeKeyNotification, #selector(windowBecameVisible(_:))),
            (NSWindow.didMiniaturizeNotification, #selector(windowBecameVisible(_:))),
            (NSWindow.didDeminiaturizeNotification, #selector(windowBecameVisible(_:))),
            (NSWindow.didResignKeyNotification, #selector(windowVisibilityMayHaveChanged(_:))),
            (NSWindow.willCloseNotification, #selector(windowWillClose(_:))),
            (NSApplication.didHideNotification, #selector(applicationDidHide(_:))),
            (NSApplication.didUnhideNotification, #selector(applicationDidUnhide(_:)))
        ]
        for (name, selector) in notifications {
            notificationCenter.addObserver(self, selector: selector, name: name, object: nil)
        }
        observerRegistrationCount = notifications.count
    }

    @objc private func windowBecameVisible(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let role = role(for: window) else { return }
        switch role {
        case .primary:
            primaryWindowDidBecomeVisible()
        case .auxiliary:
            visibleAuxiliaryWindowIDs.insert(ObjectIdentifier(window))
            setRegularActivation()
        }
    }

    @objc private func windowVisibilityMayHaveChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, !window.isVisible else { return }
            let id = ObjectIdentifier(window)
            guard let role = role(for: window) else { return }
            switch role {
            case .primary:
                primaryWindowDidBecomeHidden()
            case .auxiliary:
                visibleAuxiliaryWindowIDs.remove(id)
                reconcileActivationPolicy()
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        guard let role = role(for: window) else { return }
        rolesByWindowID.removeValue(forKey: id)
        switch role {
        case .primary:
            primaryWindow = nil
            isWindowCreationInFlight = false
            primaryWindowDidClose()
        case .auxiliary:
            visibleAuxiliaryWindowIDs.remove(id)
            reconcileActivationPolicy()
        }
    }

    private func role(for window: NSWindow) -> WindowRole? {
        if let registeredRole = rolesByWindowID[ObjectIdentifier(window)] {
            return registeredRole
        }
        if window === primaryWindow || window.identifier == Self.mainWindowIdentifier {
            return .primary
        }
        return nil
    }

    @objc private func applicationDidHide(_ notification: Notification) {
        if primaryWindow != nil {
            primaryWindowDidBecomeHidden()
        }
    }

    @objc private func applicationDidUnhide(_ notification: Notification) {
        if let primaryWindow, primaryWindow.isVisible {
            primaryWindowDidBecomeVisible()
        }
    }

    private func reconcileActivationPolicy() {
        if mainWindowState == .visible
            || mainWindowState == .opening
            || isAuxiliaryPresentationPending
            || !visibleAuxiliaryWindowIDs.isEmpty
            || !syntheticVisibleAuxiliaryIDs.isEmpty {
            setRegularActivation()
        } else {
            applyActivationPolicy(.accessory)
        }
    }

    private func setRegularActivation() {
        applyActivationPolicy(.regular)
    }

    private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard appliedActivationPolicy != policy else { return }
        let succeeded = activationController.setActivationPolicy(policy)
        if succeeded {
            appliedActivationPolicy = policy
        }
        let policyName = policy == .regular ? "regular" : "accessory"
        PeerNestLog.lifecycle.info(
            "Activation policy transition to \(policyName, privacy: .public): \(succeeded ? "succeeded" : "failed", privacy: .public)"
        )
    }

    private func clearPendingAuxiliaryPresentationLater() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            isAuxiliaryPresentationPending = false
            reconcileActivationPolicy()
        }
    }

    private func clearWindowCreationInFlightLater() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, primaryWindow == nil else { return }
            isWindowCreationInFlight = false
        }
    }
}

extension Notification.Name {
    static let openPeerNestMainWindow = Notification.Name("openPeerNestMainWindow")
}
