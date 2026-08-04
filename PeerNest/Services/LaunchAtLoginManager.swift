import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case enabled, disabled, requiresApproval, notFound, unsupported, error(String)

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .requiresApproval: "Requires Approval"
        case .notFound: "Not Found"
        case .unsupported: "Unsupported"
        case let .error(message): message
        }
    }
}

@MainActor
@Observable
final class LaunchAtLoginManager {
    private(set) var state: LaunchAtLoginState = .disabled

    init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .enabled
        case .notRegistered: state = .disabled
        case .requiresApproval: state = .requiresApproval
        case .notFound: state = .notFound
        @unknown default: state = .unsupported
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
