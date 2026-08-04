//
//  SettingsSubscriptionPlanTests.swift
//  HangsTests
//
//  #123 Track A: SettingsView.subscriptionPlanDisplay used to return the
//  literal "Free" whenever usageInfo hadn't loaded yet — briefly telling an
//  unlimited subscriber they were on the free plan. This pins the corrected
//  behavior: a nil usageInfo reads as loading, never as a (possibly wrong)
//  plan answer.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Settings subscription row before usage loads (#123)")
@MainActor
struct SettingsSubscriptionPlanTests {
    @Test("Row shows a loading label, not the literal Free, while usageInfo is nil")
    func subscriptionRowReadsAsLoadingBeforeUsageLoads() async throws {
        let mock = MockNetworkService()
        // Every /usage attempt fails, so usageInfo deterministically stays
        // nil for the whole test — no race against the background reconcile.
        mock.getUsageError = NetworkError.invalidResponse
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: vm)
            .environmentObject(appState)
            .environmentObject(NavigationModel())

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Loading…")
            }
            #expect(throws: (any Error).self) {
                try tree.find(text: "Free")
            }
        }
    }
}
