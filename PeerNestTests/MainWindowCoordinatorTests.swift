import AppKit
import Foundation
import Testing
@testable import PeerNest

@MainActor
struct MainWindowCoordinatorTests {
    @Test func launchRegistersObserversOnceAndUsesRegularPolicy() {
        let activation = FakeApplicationActivationController()
        let coordinator = MainWindowCoordinator(
            activationController: activation,
            notificationCenter: NotificationCenter()
        )

        coordinator.start()
        coordinator.start()

        #expect(coordinator.observerRegistrationCount == 7)
        #expect(activation.policies == [.regular])
    }

    @Test func primaryVisibilityControlsActivationPolicy() {
        let (coordinator, activation) = makeCoordinator()

        coordinator.primaryWindowDidBecomeVisible()
        #expect(coordinator.mainWindowState == .visible)
        #expect(activation.policies.last == .regular)

        coordinator.primaryWindowDidClose()
        #expect(coordinator.mainWindowState == .closed)
        #expect(activation.policies.last == .accessory)
    }

    @Test func closingSettingsDoesNotHideDockWhilePrimaryIsVisible() {
        let (coordinator, activation) = makeCoordinator()
        let settingsID = UUID()

        coordinator.primaryWindowDidBecomeVisible()
        coordinator.auxiliaryWindowDidBecomeVisible(testID: settingsID)
        coordinator.auxiliaryWindowDidClose(testID: settingsID)

        #expect(coordinator.mainWindowState == .visible)
        #expect(activation.policies.last == .regular)
    }

    @Test func auxiliaryWindowKeepsRegularPolicyAfterPrimaryCloses() {
        let (coordinator, activation) = makeCoordinator()
        let aboutID = UUID()

        coordinator.primaryWindowDidBecomeVisible()
        coordinator.auxiliaryWindowDidBecomeVisible(testID: aboutID)
        coordinator.primaryWindowDidClose()
        #expect(activation.policies.last == .regular)

        coordinator.auxiliaryWindowDidClose(testID: aboutID)
        #expect(activation.policies.last == .accessory)
    }

    @Test func repeatedOpenRequestsDoNotCreateDuplicatePrimaryWindows() {
        let (coordinator, activation) = makeCoordinator()
        var creationCount = 0

        coordinator.showMainWindow { creationCount += 1 }
        coordinator.showMainWindow { creationCount += 1 }

        #expect(creationCount == 1)
        #expect(coordinator.mainWindowState == .opening)
        #expect(activation.activationCount == 2)
    }

    @Test func fiveCloseOpenCyclesRestoreRegularPolicyWithoutStoppingCoordinator() {
        let (coordinator, activation) = makeCoordinator()
        var creationCount = 0

        for _ in 0..<5 {
            coordinator.showMainWindow { creationCount += 1 }
            coordinator.primaryWindowDidBecomeVisible()
            coordinator.primaryWindowDidClose()
        }

        #expect(creationCount == 5)
        #expect(coordinator.observerRegistrationCount == 7)
        #expect(activation.policies.contains(.regular))
        #expect(activation.policies.last == .accessory)
    }

    @Test func criticalInteractionRestoresForegroundMode() {
        let (coordinator, activation) = makeCoordinator()
        coordinator.primaryWindowDidClose()

        coordinator.requestCriticalInteraction()

        #expect(coordinator.mainWindowState == .opening)
        #expect(activation.policies.last == .regular)
        #expect(activation.activationCount == 1)
    }

    private func makeCoordinator() -> (MainWindowCoordinator, FakeApplicationActivationController) {
        let activation = FakeApplicationActivationController()
        let coordinator = MainWindowCoordinator(
            activationController: activation,
            notificationCenter: NotificationCenter()
        )
        coordinator.start()
        return (coordinator, activation)
    }
}

@MainActor
private final class FakeApplicationActivationController: ApplicationActivationControlling {
    private(set) var policies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        if policies.last != activationPolicy {
            policies.append(activationPolicy)
        }
        return true
    }

    func activate() {
        activationCount += 1
    }
}
