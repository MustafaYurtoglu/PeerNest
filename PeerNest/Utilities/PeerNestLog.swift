import Foundation
import OSLog

enum PeerNestLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mustafayurtoglu.PeerNest"
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    static let synchronization = Logger(subsystem: subsystem, category: "synchronization")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    static let finderExtension = Logger(subsystem: subsystem, category: "finderExtension")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let security = Logger(subsystem: subsystem, category: "security")
}
