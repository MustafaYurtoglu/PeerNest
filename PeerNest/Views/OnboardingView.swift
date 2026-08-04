import AppKit
import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    @Bindable var preferences: PreferencesStore
    let lifecycle: AppLifecycleCoordinator
    @Binding var isPresented: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 24) {
            Image("PeerNestBrand")
                .interpolation(.high)
                .antialiased(true)
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                .accessibilityLabel("PeerNest logo")
            Group {
                switch page {
                case 0: pageView("Welcome to PeerNest", "Synchronize folders directly with nearby Macs. No cloud account is required.", "network")
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        pageView(
                            "How PeerNest Runs",
                            "PeerNest stays active in the menu bar when its window is closed. The Dock icon returns whenever you reopen the window.",
                            "menubar.rectangle"
                        )
                        Label("Synchronization continues while the window is closed", systemImage: "checkmark.circle")
                    }
                case 2: pageView("Local Network", "PeerNest uses Bonjour to discover paired devices and transfers data only over your local network.", "wifi")
                case 3: pageView("Finder Integration", "Enable the PeerNest Finder extension in System Settings to share folders from the contextual menu.", "folder.badge.gearshape")
                default:
                    VStack(spacing: 12) {
                        pageView("Ready", "Add a shared folder now or find a nearby device from the main window.", "checkmark.circle")
                        Button("Add Shared Folder") { Task { await appState.addSharedFolder() } }
                    }
                }
            }
            .frame(maxWidth: 420, minHeight: 150)

            HStack {
                Button("Skip") { finish() }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                Button(page == 4 ? "Done" : "Continue") {
                    if page == 4 { finish() } else { page += 1 }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 520, height: 430)
    }

    private func pageView(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: symbol).font(.title2.bold())
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        preferences.onboardingCompleted = true
        isPresented = false
    }
}
