//
//  OnboardingViewModelTests.swift
//  HangsTests
//
//  #52 task 52.5 — onboarding navigation + permission state machine, slimmed
//  in #237 to Microphone → Voice commands.
//
//  Why these tests matter:
//  - The granted/denied branch decides whether voice-first quizzing works at all;
//    a regression that skips the denied page strands users with no mic and no explanation.
//  - #237: speech recognition is asked for ONLY by "Turn on commands" — the
//    founder's complaint was a system alert nobody asked for. Every other path
//    must finish without it, and "Maybe later" must not show the commands page
//    (commands cannot work without the mic).
//  - The persisted first-launch gate is what keeps onboarding from re-appearing on
//    every cold launch.
//  - The Settings replay (founder decision 2026-06-11) must NOT clear or depend on
//    `hasCompletedOnboarding` — clearing it would re-trigger onboarding on next launch.
//

import Foundation
@testable import Hangs
import Testing

/// Counts how often the onboarding turned commands on (the prompt's one door).
@MainActor
final class EnableCommandsSpy {
    private(set) var calls = 0
    /// `true`: the call parks until `release()` — the system prompt is up.
    var holds = false
    private(set) var held: CheckedContinuation<Void, Never>?

    func enable() async {
        calls += 1
        if holds { await withCheckedContinuation { held = $0 } }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@MainActor
private func makeOnboardingViewModel(
    micGranted: Bool = true,
    hasCompletedOnboarding: Bool = false,
    analytics: AnalyticsClient = NoopAnalyticsClient(),
    spy: EnableCommandsSpy = EnableCommandsSpy()
) -> (OnboardingViewModel, MockPersistenceStore, EnableCommandsSpy) {
    let audio = MockAudioService()
    audio.micPermissionResult = micGranted
    let store = MockPersistenceStore()
    store.hasCompletedOnboarding = hasCompletedOnboarding
    let viewModel = OnboardingViewModel(
        audioService: audio, persistenceStore: store, analytics: analytics,
        enableCommands: { await spy.enable() }
    )
    return (viewModel, store, spy)
}

@MainActor
@Suite("OnboardingViewModel state machine")
struct OnboardingViewModelTests {
    @Test("starts on the microphone page")
    func startsOnMicrophone() {
        let (vm, _, _) = makeOnboardingViewModel()
        #expect(vm.page == .microphone)
        #expect(!vm.isComplete)
    }

    @Test("granted mic leads to the commands page, not to the end — and asks nothing about speech yet")
    func grantedShowsCommandsPage() async {
        let (vm, store, spy) = makeOnboardingViewModel(micGranted: true)

        await vm.requestMicPermission()

        #expect(vm.micPermissionGranted)
        #expect(vm.page == .commands)
        #expect(!vm.isComplete)
        #expect(!store.hasCompletedOnboarding)
        #expect(spy.calls == 0, "speech recognition is asked only by Turn on commands")
    }

    @Test("Turn on commands asks once, then finishes whatever iOS answered")
    func turnOnCommandsFinishes() async {
        let (vm, store, spy) = makeOnboardingViewModel(micGranted: true)
        await vm.requestMicPermission()

        await vm.turnOnCommands()

        #expect(spy.calls == 1)
        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("while the prompt is up the page is busy, and a second tap cannot ask twice")
    func turnOnCommandsIsSingleFlight() async {
        let (vm, _, spy) = makeOnboardingViewModel(micGranted: true)
        await vm.requestMicPermission()
        spy.holds = true

        let first = Task { await vm.turnOnCommands() }
        await pumpUntil({ spy.held != nil }, "the prompt never opened")
        #expect(vm.isEnablingCommands)
        await vm.turnOnCommands()
        #expect(spy.calls == 1)
        #expect(!vm.isComplete, "the onboarding waits for the player's answer")

        spy.release()
        await first.value
        #expect(vm.isComplete)
        #expect(!vm.isEnablingCommands)
    }

    @Test("Not now on the commands page finishes without asking")
    func notNowFinishesWithoutPrompt() async {
        let (vm, store, spy) = makeOnboardingViewModel(micGranted: true)
        await vm.requestMicPermission()

        vm.skipCommands()

        #expect(spy.calls == 0)
        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("Maybe later on the microphone page finishes and skips the commands page")
    func maybeLaterSkipsCommands() {
        let (vm, store, spy) = makeOnboardingViewModel()

        vm.continueWithoutMic()

        #expect(vm.isComplete)
        #expect(vm.page == .microphone, "commands without a mic would be a dead end")
        #expect(store.hasCompletedOnboarding)
        #expect(spy.calls == 0)
    }

    @Test("denied mic permission routes to the denied page without completing")
    func deniedBranch() async {
        let (vm, store, _) = makeOnboardingViewModel(micGranted: false)

        await vm.requestMicPermission()

        #expect(!vm.micPermissionGranted)
        #expect(vm.page == .permissionDenied)
        #expect(!vm.isComplete)
        #expect(!store.hasCompletedOnboarding)
    }

    @Test("continueWithoutMic exits the denied page, never through the commands page")
    func deniedThenContinue() async {
        let (vm, store, spy) = makeOnboardingViewModel(micGranted: false)
        await vm.requestMicPermission()

        vm.continueWithoutMic()

        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
        #expect(spy.calls == 0)
    }

    @Test("the commands page's buttons do nothing on another page")
    func commandsActionsAreScopedToTheirPage() async {
        let (vm, _, spy) = makeOnboardingViewModel()
        await vm.turnOnCommands()
        vm.skipCommands()
        #expect(spy.calls == 0)
        #expect(!vm.isComplete)
    }

    @Test("first-launch gate: presents while flag unset, not after completion (relaunch)")
    func firstLaunchGate() async {
        let (vm, store, _) = makeOnboardingViewModel(micGranted: true)
        #expect(OnboardingViewModel.shouldPresentOnFirstLaunch(persistenceStore: store))

        await vm.requestMicPermission()
        vm.skipCommands()

        #expect(!OnboardingViewModel.shouldPresentOnFirstLaunch(persistenceStore: store))
    }

    @Test("startOnboarding replays from the microphone page without touching the persisted flag")
    func settingsReplay() async {
        let (vm, store, _) = makeOnboardingViewModel(micGranted: true, hasCompletedOnboarding: true)
        await vm.requestMicPermission()
        vm.skipCommands()

        vm.startOnboarding()

        #expect(vm.page == .microphone)
        #expect(!vm.isComplete)
        // Replay must not clear the flag — clearing would re-trigger first-launch onboarding
        #expect(store.hasCompletedOnboarding)

        await vm.requestMicPermission()
        await vm.turnOnCommands()
        #expect(vm.isComplete)
        #expect(store.hasCompletedOnboarding)
    }

    @Test("two dots; the denied page stays on the microphone dot")
    func pageIndicatorMapping() async {
        let (granted, _, _) = makeOnboardingViewModel(micGranted: true)
        #expect(granted.pageCount == 2)
        #expect(granted.pageIndex == 0)
        await granted.requestMicPermission()
        #expect(granted.pageIndex == 1)

        let (denied, _, _) = makeOnboardingViewModel(micGranted: false)
        await denied.requestMicPermission()
        #expect(denied.pageIndex == 0, "the denied page is the mic step's outcome, not a third dot")
    }

    @Test("the commands card shows real command words in the command language")
    func commandWordsComeFromTheLexicon() {
        #expect(OnboardingViewModel.commandWords(language: .slovak) == ["„ďalšia“", "„zopakuj“", "„odpovedz“"])
        #expect(OnboardingViewModel.commandWords(language: .czech) == ["„další“", "„zopakuj“", "„odpověz“"])
        #expect(OnboardingViewModel.commandWords(language: .english) == ["“next”", "“repeat”", "“answer”"])
        #expect(OnboardingViewModel.commandWords(language: .ukrainian) == ["«пропусти»", "«повтори»", "«відповідай»"])
    }

    @Test("onboarding_finished names how and on which page it ended")
    func outcomes() async {
        let analytics = MockAnalyticsClient()
        let (later, _, _) = makeOnboardingViewModel(analytics: analytics)
        later.continueWithoutMic()
        let (denied, _, _) = makeOnboardingViewModel(micGranted: false, analytics: analytics)
        await denied.requestMicPermission()
        denied.continueWithoutMic()
        let (on, _, _) = makeOnboardingViewModel(analytics: analytics)
        await on.requestMicPermission()
        await on.turnOnCommands()
        let (notNow, _, _) = makeOnboardingViewModel(analytics: analytics)
        await notNow.requestMicPermission()
        notNow.skipCommands()

        #expect(analytics.events == [
            .onboardingFinished(outcome: .micLater, step: "microphone"),
            .onboardingFinished(outcome: .micDenied, step: "permissionDenied"),
            .onboardingFinished(outcome: .commandsOn, step: "commands"),
            .onboardingFinished(outcome: .commandsLater, step: "commands"),
        ])
    }
}

// MARK: - AI services consent (#209, guideline 5.1.2(i))

/// App Review requires explicit consent before spoken answers and typed topics
/// reach third-party AI services. #237 moved the disclosure to the microphone
/// page (the first one), above both of its buttons, so leaving it either way
/// is the consent, and nothing else may count: a consent recorded before the
/// player saw the text is void.
@MainActor
@Suite("Onboarding AI services consent (#209)")
struct OnboardingAIConsentTests {
    private func make(micGranted: Bool = true) -> (OnboardingViewModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "OnboardingAIConsentTests.\(UUID().uuidString)")!
        let audio = MockAudioService()
        audio.micPermissionResult = micGranted
        let vm = OnboardingViewModel(
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            consentDefaults: defaults,
            enableCommands: {}
        )
        return (vm, defaults)
    }

    @Test("no consent before the player leaves the microphone page")
    func noConsentUpFront() {
        let (_, defaults) = make()
        #expect(!AIProcessingConsent.hasConsented(defaults: defaults))
    }

    @Test("Allow on the microphone page records consent, granted or not", arguments: [true, false])
    func allowConsents(micGranted: Bool) async {
        let (vm, defaults) = make(micGranted: micGranted)
        await vm.requestMicPermission()
        #expect(AIProcessingConsent.hasConsented(defaults: defaults))
    }

    @Test("Maybe later on the microphone page records consent too")
    func maybeLaterConsents() {
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
