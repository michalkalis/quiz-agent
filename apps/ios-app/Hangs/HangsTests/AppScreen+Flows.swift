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
        case .onboardingWelcome: await Self.onboarding(advances: 0)
        case .onboardingFeatures: await Self.onboarding(advances: 1)
        case .onboardingPermission: await Self.onboarding(advances: 2)
        case .onboardingDenied: await Self.onboarding(advances: 2, micDenied: true)
        case .signInIdle: Self.signIn(.idle)
        case .signInSigningIn: Self.signIn(.signingIn)
        case .signInFailed: Self.signIn(.failed)
        case .orderForm, .orderSummary, .orderPreparing, .orderReadyGenerating, .orderReady, .orderFailed:
            await makeOrder()
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

    /// `advances` walks welcome → features → permission; `micDenied` then answers
    /// the permission request with "no", which lands on the denied page.
    private static func onboarding(advances: Int, micDenied: Bool = false) async -> AnyView {
        let audio = MockAudioService()
        audio.micPermissionResult = !micDenied
        let vm = OnboardingViewModel(audioService: audio, persistenceStore: MockPersistenceStore())
        for _ in 0 ..< advances { vm.advance() }
        if micDenied { await vm.requestMicPermission() }
        return AnyView(OnboardingView(viewModel: vm))
    }

    // MARK: Contextual sign-in

    private static func signIn(_ phase: ContextualSignInSheet.Phase) -> AnyView {
        AnyView(ContextualSignInSheet(
            authService: AuthService(baseURL: Config.apiBaseURL),
            initialPhase: phase,
            onDismiss: {}
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
            purchaseService: MockPackPurchaseService(),
            adminKeyAvailable: { true },
            clock: AnyClock(clock)
        )
        vm.prompt = "Famous bridges of the world and the engineers who built them"
        switch self {
        case .orderForm:
            break
        case .orderSummary:
            vm.advanceToSummary()
        default:
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
