import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServiceContainer()
    var appState: AppState { services.appState }
    private var terminationReplySent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let brandIcon = NSImage(named: "PeerNestBrand") {
            NSApplication.shared.applicationIconImage = brandIcon
        }
        #if DEBUG
        if let menuBarImage = NSImage(named: "PeerNestMenuBar") {
            PeerNestLog.lifecycle.info(
                "PeerNestMenuBar asset loaded successfully (\(Int(menuBarImage.size.width))x\(Int(menuBarImage.size.height)), template: \(menuBarImage.isTemplate))"
            )
        } else {
            PeerNestLog.lifecycle.error("PeerNestMenuBar asset failed to load")
        }
        #endif
        services.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            services.mainWindowCoordinator.requestMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplySent else { return .terminateNow }
        Task { @MainActor [weak self, weak sender] in
            await self?.services.shutdown()
            self?.finishTermination(sender)
        }
        Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(3))
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    func requestQuit() {
        PeerNestLog.lifecycle.info("Explicit Quit PeerNest requested")
        NSApplication.shared.terminate(nil)
    }

    private func finishTermination(_ application: NSApplication?) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        application?.reply(toApplicationShouldTerminate: true)
    }
}
