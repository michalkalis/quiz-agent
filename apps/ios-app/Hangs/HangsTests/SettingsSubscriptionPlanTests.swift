//
//  SettingsSubscriptionPlanTests.swift
//  HangsTests
//
//  #123 Track A: SettingsView.subscriptionPlanDisplay used to return the
//  literal "Free" whenever usageInfo hadn't loaded yet — briefly telling a
//  subscriber they were on the free plan. This pins the corrected behavior:
//  a nil usageInfo reads as loading, never as a (possibly wrong) plan answer.
//  #199: a Trubbo Plus subscriber reads the plan name and what is left of the
//  month's allowance.
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
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
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

    private func subscriberRow(usage: UsageInfo) async throws -> SettingsView {
        let mock = MockNetworkService()
        mock.stubbedUsage = usage
        let vm = QuizViewModel(
            networkService: mock,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
        await pumpUntil({ vm.usageInfo == usage }, "the stubbed /usage never loaded")
        return SettingsView(viewModel: vm)
    }

    private func usage(remaining: Int?, limit: Int?) -> UsageInfo {
        UsageInfo(
            userId: "test-subject", isPremium: true, questionsUsed: 130,
            questionsLimit: limit, remaining: remaining,
            resetsAt: "", subscriptionStatus: "active", creditBalance: 0
        )
    }

    @Test("A Trubbo Plus subscriber sees the plan and what is left of the month, never 'Unlimited' (#199)")
    func subscriberRowShowsPlanAndRemainingAllowance() async throws {
        let settings = try await subscriberRow(usage: usage(remaining: 870, limit: 1000))
        let view = settings
            .environmentObject(AppState(
                networkService: MockNetworkService(),
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore()
            ))
            .environmentObject(NavigationModel())

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                // Grouping follows the process locale (1,000 / 1 000), like the app does.
                try tree.find(text: "Trubbo Plus · 870 of \(1000.formatted()) left")
            }
            #expect(throws: (any Error).self) {
                try tree.find(text: "Unlimited")
            }
        }
    }

    @Test("A subscriber payload without a limit still names the plan instead of inventing a count (#199)")
    func subscriberRowWithoutLimitShowsPlanName() async throws {
        let settings = try await subscriberRow(usage: usage(remaining: nil, limit: nil))
        let view = settings
            .environmentObject(AppState(
                networkService: MockNetworkService(),
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore()
            ))
            .environmentObject(NavigationModel())

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Trubbo Plus")
            }
        }
    }
}
