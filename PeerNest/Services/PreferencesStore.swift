import Foundation
import Observation

@MainActor
@Observable
final class PreferencesStore {
    private enum Key {
        static let launchAtLoginIntent = "preferences.launchAtLoginIntent"
        static let startServicesAutomatically = "preferences.startServicesAutomatically"
        static let onboardingCompleted = "preferences.onboardingCompleted"
        static let conflictNotifications = "preferences.conflictNotifications"
        static let failureNotifications = "preferences.failureNotifications"
        static let reconciliationNotifications = "preferences.reconciliationNotifications"
        static let storageNotifications = "preferences.storageNotifications"
    }

    private let defaults: UserDefaults

    var launchAtLoginIntent: Bool { didSet { defaults.set(launchAtLoginIntent, forKey: Key.launchAtLoginIntent) } }
    var startServicesAutomatically: Bool { didSet { defaults.set(startServicesAutomatically, forKey: Key.startServicesAutomatically) } }
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    var conflictNotifications: Bool { didSet { defaults.set(conflictNotifications, forKey: Key.conflictNotifications) } }
    var failureNotifications: Bool { didSet { defaults.set(failureNotifications, forKey: Key.failureNotifications) } }
    var reconciliationNotifications: Bool { didSet { defaults.set(reconciliationNotifications, forKey: Key.reconciliationNotifications) } }
    var storageNotifications: Bool { didSet { defaults.set(storageNotifications, forKey: Key.storageNotifications) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLoginIntent = defaults.bool(forKey: Key.launchAtLoginIntent)
        startServicesAutomatically = defaults.object(forKey: Key.startServicesAutomatically) as? Bool ?? true
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        conflictNotifications = defaults.object(forKey: Key.conflictNotifications) as? Bool ?? true
        failureNotifications = defaults.object(forKey: Key.failureNotifications) as? Bool ?? true
        reconciliationNotifications = defaults.object(forKey: Key.reconciliationNotifications) as? Bool ?? true
        storageNotifications = defaults.object(forKey: Key.storageNotifications) as? Bool ?? true
    }
}
