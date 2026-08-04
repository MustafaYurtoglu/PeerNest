import AppKit
import SwiftUI

struct PeerNestWindowBridge: NSViewRepresentable {
    let role: MainWindowCoordinator.WindowRole
    let coordinator: MainWindowCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = WindowReadingView(frame: .zero)
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.register(window, role: role)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            coordinator.register(window, role: role)
        }
    }
}

@MainActor
private final class WindowReadingView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowChange?(window)
        }
    }
}
