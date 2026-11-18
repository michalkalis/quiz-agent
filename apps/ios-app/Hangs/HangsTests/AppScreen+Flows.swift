//
//  AppScreen+Flows.swift
//  HangsTests
//
//  #194 A2: builders for Settings, Onboarding, the order-pack flow and the
//  contextual sign-in sheet. See AppScreenSnapshotTests.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

extension AppScreen {
    func makeFlow() async -> AnyView {
        switch self {
        case .settings: Self.settings()
        case .onboardingPermission: await Self.onboarding(micAnswer: nil)
        case .onboardingCommands: await Self.onboarding(micAnswer: true)
        case .onboardingDenied: await Self.onboarding(micAnswer: false)
        case .signInIdle: Self.signIn(.idle)
        case .signInSigningIn: Self.signIn(.signingIn)
        case .signInFailed: Self.signIn(.failed)
        case .signInCredit: Self.signIn(.idle, purchase: .credit(questionCount: 100))
        case .signInPack: Self.signIn(.idle, purchase: .customPack(name: "Harry Potter", questionCount: 30, colorKey: "order-1"))
        case .orderForm, .orderSummary, .orderPreparing, .orderReadyGenerating, .orderReady, .orderFailed:
            await makeOrder()
        case .paywallPack, .paywallAllowanceSpent, .paywallOffline:
            await makePaywall()
        case .homeCredits, .homeSubscriber, .homeGrace, .homeExpired, .homePacks, .homeCategories:
            await makeHome()
        case .myPacks:
            await makePacks()
        case .myPacksLoadFailed:
            await makePacksLoadFailed()
        case .dailyEndGood, .dailyEndWeak, .homeDaily, .homeDailyPlayed:
            await makeDaily()
        case .roomLobbyHost, .roomLobbyGuest, .roomQuestion, .roomQuestionHost, .roomReveal, .roomRevealTyped, .roomRevealPaused, .roomFinal, .roomFinalExpanded, .roomRules, .roomRulesLobby, .roomLobbyHostFull:
            await makeRoom()
        case .recapShareImage:
            makeRecapShareImage()
        case .sharedQuizRanking, .homeSharedPaste, .roomContentPicker:
            await makeSharedQuiz()
        case .profile, .profileNewPlayer, .profileLoadFailed, .allStats:
            await makeProfile()
        default: preconditionFailure("\(self) is built in AppScreen+Quiz")
        }
    }

    // MARK: Settings

    private static func settings() -> AnyView {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        return AnyView(
            NavigationStack {
                SettingsView(viewModel: Fixtures.makeViewModel(clock: AnyClock(TestClock())))
            }
            .environmentObject(appState)
            .environmentObject(NavigationModel())
        )
    }

    // MARK: Onboarding

    /// #237: the microphone page (`micAnswer` nil), or the page the mic
    /// answer leads to — commands when allowed, the denied page when not.
    private static func onboarding(micAnswer: Bool?) async -> AnyView {
        let audio = MockAudioService()
        audio.micPermissionResult = micAnswer ?? true
        let vm = OnboardingViewModel(audioService: audio, persistenceStore: MockPersistenceStore(), enableCommands: {})
        if micAnswer != nil { await vm.requestMicPermission() }
        return AnyView(OnboardingView(viewModel: vm))
    }

    // MARK: Contextual sign-in

    private static func signIn(_ phase: ContextualSignInSheet.Phase, purchase: SignInPromptPurchase = .plus) -> AnyView {
        AnyView(ContextualSignInSheet(
            purchase: purchase,
            authService: AuthService(baseURL: Config.apiBaseURL),
            initialPhase: phase,
            onFinish: { _ in }
        ))
    }

    // MARK: Order pack

    /// Each state is reached by driving the real view model, because `state` is
    /// `private(set)`. A `TestClock` parks the delivery poll after its first answer,
    /// so the "preparing" and "still generating" screens stay settled.
    private func makeOrder() async -> AnyView {
        let clock = TestClock<Duration>()
        let service = MockPackOrderService(getResult: .success(orderSnapshot))
        let vm = OrderPackViewModel(
            service: service,
            purchaseService: MockPackPurchaseService(prices: [.ten: "3,49 €", .thirty: "8,99 €"]),
            adminKeyAvailable: { true },
            // Pinned to the server default, and no live fetch: the menu must not
            // depend on what the test host happens to have cached.
            orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
            refreshLanguages: {},
            clock: AnyClock(clock)
        )
        vm.prompt = "Famous bridges of the world and the engineers who built them"
        switch self {
        case .orderForm:
            // The required-choice state: nothing picked, Continue disabled (#224).
            break
        case .orderSummary:
            vm.selectDifficulty(.medium)
            vm.advanceToSummary()
            // Loaded up front: the summary's own `.task` load isn't awaited by a snapshot.
            await vm.loadPrice()
        default:
            vm.selectDifficulty(.medium)
            vm.advanceToSummary()
            // Fire-and-forget: `submit()` only returns once the order is terminal,
            // and the parked poll never gets there. Retained by the VM's `pollTask`.
            Task { await vm.submit() }
            await pumpUntil({ vm.state != .confirming && vm.state != .submitting })
            if case .polling(nil) = vm.state {
                await pumpUntil({ if case .polling(nil) = vm.state { false } else { true } })
            }
        }
        return AnyView(OrderPackFlowView(viewModel: vm, onPlayPack: { _ in }, onClose: {}))
    }

    private var orderSnapshot: OrderSnapshot {
        switch self {
        case .orderPreparing: .mockPending
        case .orderReadyGenerating: .mockGenerating
        case .orderFailed: .mockFailed
        default: .mockDelivered
        }
    }
}
