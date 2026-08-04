//
//  PeerNestApp.swift
//  PeerNest
//
//  Created by mustafa on 3.08.2026.
//

import AppKit
import OSLog
import SwiftUI

@main
struct PeerNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PeerNestLog.lifecycle.info("Active @main PeerNestApp initialized")
        PeerNestLog.lifecycle.info("PeerNestApp.body scene construction scheduled")
    }

    var body: some Scene {
        Window("PeerNest", id: MainWindowCoordinator.mainSceneID) {
            ContentView(
                appState: appDelegate.appState,
                preferences: appDelegate.services.preferences,
                lifecycle: appDelegate.services.lifecycle
            )
            .background(PeerNestWindowBridge(
                role: .primary,
                coordinator: appDelegate.services.mainWindowCoordinator
            ))
        }
        .commands {
            PeerNestCommands(
                preferences: appDelegate.services.preferences,
                lifecycle: appDelegate.services.lifecycle
            )
        }

        MenuBarExtra {
            PeerNestMenuBarView(
                appState: appDelegate.appState,
                lifecycle: appDelegate.services.lifecycle,
                quitAction: appDelegate.requestQuit
            )
        } label: {
            PeerNestMenuBarLabel(
                appState: appDelegate.appState,
                lifecycle: appDelegate.services.lifecycle
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PeerNestSettingsView(
                appState: appDelegate.appState,
                preferences: appDelegate.services.preferences,
                launchAtLogin: appDelegate.services.launchAtLogin,
                lifecycle: appDelegate.services.lifecycle,
                mainWindowCoordinator: appDelegate.services.mainWindowCoordinator
            )
        }
    }
}

private struct PeerNestCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let preferences: PreferencesStore
    let lifecycle: AppLifecycleCoordinator

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About PeerNest") {
                lifecycle.showAboutPanel()
            }
        }

        CommandGroup(after: .help) {
            Button("PeerNest Onboarding") {
                preferences.onboardingCompleted = false
                lifecycle.showMainWindow {
                    openWindow(id: MainWindowCoordinator.mainSceneID)
                }
            }
        }
    }
}
