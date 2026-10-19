//
//  OnboardingViewModelTests.swift
//  HangsTests
//
//  #52 task 52.5 — onboarding navigation + permission state machine.
//
//  Why these tests matter:
//  - The granted/denied branch decides whether voice-first quizzing works at all;
//    a regression that skips the denied page strands users with no mic and no explanation.
//  - The persisted first-launch gate is what keeps onboarding from re-appearing on
//    every cold launch.
//  - The Settings replay (founder decision 2026-06-11) must NOT clear or depend on
//    `hasCompletedOnboarding` — clearing it would re-trigger onboarding on next launch.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeOnboardingViewModel(
    micGranted: Bool = true,
    hasCompletedOnboarding: Bool = false
) -> (OnboardingViewModel, MockAudioService, MockPersistenceStore) {
    let audio = MockAudioService()
    audio.micPermissionResult = micGranted
    let store = MockPersistenceStore()
    store.hasCompletedOnboarding = hasCompletedOnboarding
    let viewModel = OnboardingViewModel(audioService: audio, persistenceStore: store)
    return (viewModel, audio, store)
}

@MainActor
@Suite("OnboardingViewModel state machine")
struct OnboardingViewModelTests {
    @Test("advance walks Welcome → Features → Permission and stops there")
    func linearAdvance() {
        let (vm, _, _) = makeOnboardingViewModel()

        #expect(vm.page == .welcome)
        vm.advance()
        #expect(vm.page == .features)
        vm.advance()
        #expect(vm.page == .permission)
        // Permission resolves via requestMicPermission(), never advance()
        vm.advance()
        #expect(vm.page == .permission)
        #expect(!vm.isComplete)
    }

    @Test("granted mic permission completes the flow and persists the flag")
    func grantedBranch() async {
        let (vm, _, store) = makeOnboardingViewModel(micGranted: true)
        vm.advance()
        vm.advance()

        await vm.requestMicPermission()

        #expect(vm.micPermissionGranted)
        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("denied mic permission routes to 3b-Denied without completing")
    func deniedBranch() async {
        let (vm, _, store) = makeOnboardingViewModel(micGranted: false)
        vm.advance()
        vm.advance()

        await vm.requestMicPermission()

        #expect(!vm.micPermissionGranted)
        #expect(vm.page == .permissionDenied)
        #expect(!vm.isComplete)
        #expect(!store.hasCompletedOnboarding)
    }

    @Test("continueWithoutMic exits the denied page and persists the flag")
    func deniedThenContinue() async {
        let (vm, _, store) = makeOnboardingViewModel(micGranted: false)
        vm.advance()
        vm.advance()
        await vm.requestMicPermission()
        #expect(vm.page == .permissionDenied)

        vm.continueWithoutMic()

        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("first-launch gate: presents while flag unset, not after completion (relaunch)")
    func firstLaunchGate() async {
        let (vm, _, store) = makeOnboardingViewModel(micGranted: true)

        // First launch: flag unset → present
        #expect(OnboardingViewModel.shouldPresentOnFirstLaunch(persistenceStore: store))

        vm.advance()
        vm.advance()
        await vm.requestMicPermission()

        // Relaunch against the same store: flag persisted → don't present
        #expect(!OnboardingViewModel.shouldPresentOnFirstLaunch(persistenceStore: store))
    }

    @Test("startOnboarding replays from Welcome without touching the persisted flag")
    func settingsReplay() async {
        // Replay happens after onboarding completed once — flag already true
        let (vm, _, store) = makeOnboardingViewModel(micGranted: true, hasCompletedOnboarding: true)

        vm.startOnboarding()

        #expect(vm.page == .welcome)
        #expect(!vm.isComplete)
        // Replay must not clear the flag — clearing would re-trigger first-launch onboarding
        #expect(store.hasCompletedOnboarding)

        // Replaying through to completion leaves the flag set
        vm.advance()
        vm.advance()
        await vm.requestMicPermission()
        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("page indicator maps the denied branch onto the permission dot")
    func pageIndicatorMapping() async {
        let (vm, _, _) = makeOnboardingViewModel(micGranted: false)
        #expect(vm.pageCount == 3)
        #expect(vm.pageIndex == 0)
        vm.advance()
        #expect(vm.pageIndex == 1)
        vm.advance()
        #expect(vm.pageIndex == 2)
        await vm.requestMicPermission()
        // 3b-Denied is a branch of the permission step, not a fourth dot
        #expect(vm.pageIndex == 2)
    }
}

// MARK: - AI services consent (#209, guideline 5.1.2(i))

/// App Review requires explicit consent before spoken answers and typed topics
/// reach third-party AI services. The welcome page shows the disclosure above
/// both of its buttons, so leaving it either way is the consent, and nothing
/// else may count: a consent recorded before the player saw the text is void.
@MainActor
@Suite("Onboarding AI services consent (#209)")
struct OnboardingAIConsentTests {
    private func make() -> (OnboardingViewModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "OnboardingAIConsentTests.\(UUID().uuidString)")!
        let vm = OnboardingViewModel(
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            consentDefaults: defaults
        )
        return (vm, defaults)
    }

    @Test("no consent before the player leaves the welcome page")
    func noConsentUpFront() {
        let (_, defaults) = make()
        #expect(!AIProcessingConsent.hasConsented(defaults: defaults))
    }

    @Test("Continue on the welcome page records consent")
    func continueConsents() {
        let (vm, defaults) = make()
        vm.advance()
        #expect(AIProcessingConsent.hasConsented(defaults: defaults))
    }

    @Test("Skip on the welcome page records consent too")
    func skipConsents() {
        let (vm, defaults) = make()
        vm.continueWithoutMic()
        #expect(vm.isComplete)
        #expect(AIProcessingConsent.hasConsented(defaults: defaults))
    }

    @Test("a consent from an older disclosure text no longer counts")
    func olderVersionIsVoid() {
        let (_, defaults) = make()
        AIProcessingConsent.record(defaults: defaults)
        defaults.set(AIProcessingConsent.currentVersion - 1, forKey: AIProcessingConsent.versionKey)
        #expect(!AIProcessingConsent.hasConsented(defaults: defaults))
    }
}
