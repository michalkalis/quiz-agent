//
//  AppScreen+Home.swift
//  HangsTests
//
//  #194 C1: Home in the plan-card states the hero suite does not freeze
//  (credits, subscriber, grace, expired), the packs section and the category
//  picker sheet.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeHome() async -> AnyView {
        switch self {
        case .homeCredits: Self.home(Self.usage(status: "none", credits: 100))
        case .homeSubscriber: Self.home(Self.usage(premium: true, status: "active", credits: 100))
        case .homeGrace: Self.home(Self.usage(premium: true, status: "grace"))
        case .homeExpired: Self.home(Self.usage(remaining: 30, status: "expired"))
        case .homePacks: await Self.packs()
        case .homeCategories: Self.categories()
        default: preconditionFailure("\(self) is not a Home screen")
        }
    }

    private static func home(_ usage: UsageInfo) -> AnyView {
        let network = MockNetworkService()
        network.stubbedUsage = usage
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
        vm.usageInfo = usage
        return AnyView(HomeView(viewModel: vm))
    }

    /// The section on its own: inside Home its list loads in `.task`, which a
    /// snapshot does not wait for.
    private static func packs() async -> AnyView {
        let orders: [OrderSnapshot] = [.mockDelivered, .mockGenerating, .mockPending]
        let vm = MyPacksViewModel(service: MockPackOrderService(listResult: .success(orders)))
        await vm.refresh()
        // No NavigationStack: its bar height differs per device and would tie
        // the baseline to the simulator model.
        return AnyView(
            VStack {
                HomePacksSection(viewModel: vm, onPlayPack: { _ in })
                Spacer()
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.top, Theme.Hangs.Spacing.xl)
            .background(Theme.Hangs.Colors.bg)
        )
    }

    private static func categories() -> AnyView {
        AnyView(HomeCategoryPicker(categories: .constant(["geography-world", "history", "entertainment"])))
    }

    private static func usage(
        premium: Bool = false,
        remaining: Int = 18,
        status: String,
        credits: Int = 0
    ) -> UsageInfo {
        UsageInfo(
            userId: "snapshot-subject",
            isPremium: premium,
            questionsUsed: 12,
            questionsLimit: premium ? nil : 30,
            remaining: premium ? nil : remaining,
            // 12½ days out, so the countdown reads the same on every run.
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400 + 12 * 3600)),
            subscriptionStatus: status,
            creditBalance: credits
        )
    }
}
