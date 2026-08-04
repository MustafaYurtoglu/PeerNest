//
//  ContentView.swift
//  PeerNest
//
//  Created by mustafa on 3.08.2026.
//

import SwiftUI

struct ContentView: View {
    let appState: AppState
    let preferences: PreferencesStore
    let lifecycle: AppLifecycleCoordinator
    @State private var showsOnboarding = false

    var body: some View {
        HomeView(appState: appState)
            .onAppear { showsOnboarding = !preferences.onboardingCompleted }
            .onReceive(NotificationCenter.default.publisher(for: .showPeerNestOnboarding)) { _ in
                showsOnboarding = true
            }
            .sheet(isPresented: $showsOnboarding) {
                OnboardingView(
                    appState: appState,
                    preferences: preferences,
                    lifecycle: lifecycle,
                    isPresented: $showsOnboarding
                )
            }
    }
}

#Preview {
    let state = AppState()
    let preferences = PreferencesStore()
    let mainWindowCoordinator = MainWindowCoordinator()
    ContentView(
        appState: state,
        preferences: preferences,
        lifecycle: AppLifecycleCoordinator(
            appState: state,
            preferences: preferences,
            mainWindowCoordinator: mainWindowCoordinator
        )
    )
}
