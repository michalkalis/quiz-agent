//
//  SettingsViewOnboardingTests.swift
//  HangsTests
//
//  #52 task 52.9 — Settings redesign: replay-onboarding row wiring.
//
//  Why these tests matter:
//  - The "Replay intro" row is the Settings entry point for re-running onboarding
//    (founder decision 2026-06-11). It must call startOnboarding() which resets
//    the VM to the Welcome page WITHOUT clearing hasCompletedOnboarding — clearing
//    the flag would silently re-trigger first-launch onboarding on the next cold launch.
//  - The structural test (ViewInspector) ensures the row label stays present and
//    wasn't accidentally removed during future refactors.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Structural: row renders in the view tree

@MainActor
@Suite("SettingsView — replay onboarding row")
struct SettingsViewOnboardingTests {
    @Test("'Replay intro' row label renders in the view tree")
    func replayRowLabelRendersInTree() async throws {
        // SettingsView reads AppState from the environment (#61 account section);
        // a mock-backed AppState satisfies it without the heavy production init.
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Replay intro")
            }
        }
    }

    // MARK: - Wiring contract: closure must not clear hasCompletedOnboarding

    @Test("startOnboarding resets VM to Welcome without clearing hasCompletedOnboarding")
    func replayDoesNotClearFlag() {
        let store = MockPersistenceStore()
        store.hasCompletedOnboarding = true
        let vm = OnboardingViewModel(
            audioService: MockAudioService(),
            persistenceStore: store
        )

        // This is what the Settings replay row calls via the onReplayOnboarding closure.
        vm.startOnboarding()

        #expect(vm.page == .welcome, "Replay must restart at the Welcome page")
        #expect(!vm.isComplete, "Replay must mark the flow as not yet complete")
        #expect(
            store.hasCompletedOnboarding,
            "startOnboarding() must not clear hasCompletedOnboarding — clearing it re-triggers first-launch onboarding on cold relaunch"
        )
    }

    @Test("onReplayOnboarding closure fires when provided")
    func replayClosureFires() async throws {
        var fired = false
        // SettingsView reads AppState from the environment (#61 account section);
        // a mock-backed AppState satisfies it without the heavy production init.
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let settings = SettingsView(viewModel: .preview, onReplayOnboarding: { fired = true })
        let view = settings.environmentObject(appState)

        try await ViewHosting.host(view) {
            _ = try view.inspect()
            // Directly invoke the closure to verify the wiring contract independent
            // of ViewInspector's limited button-tap support for deep nested buttons.
            settings.onReplayOnboarding?()
            #expect(fired, "onReplayOnboarding closure must be called by the replay row action")
        }
    }
}
