//
//  OnboardingViewModel.swift
//  Hangs
//
//  Onboarding navigation + permission state machine — #52 task 52.5, slimmed
//  in #237 (founder pick 2026-11-17, canvas A without A1/A2):
//  Microphone → Voice commands.
//    - Microphone allowed → the commands page.
//    - Microphone refused → permissionDenied → done.
//    - "Maybe later" → done (commands cannot work without the mic).
//  Speech recognition is asked for only by "Turn on commands" on the second
//  page; nothing in the onboarding raises it on its own.
//

import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Page: Int, Equatable, CaseIterable {
        case microphone = 0
        case commands = 1
        /// Reached only when the mic request is refused.
        case permissionDenied = 2
    }

    @Published private(set) var page: Page = .microphone
    /// True once the flow finishes — the host view dismisses on this.
    @Published private(set) var isComplete = false
    @Published private(set) var micPermissionGranted = false
    /// "Turn on commands" is waiting for the system prompt; the page's
    /// buttons are disabled meanwhile, so a second tap cannot ask twice.
    @Published private(set) var isEnablingCommands = false

    private let audioService: AudioServiceProtocol
    private let persistenceStore: PersistenceStoreProtocol
    private let analytics: AnalyticsClient
    private let consentDefaults: UserDefaults
    /// #237: turns voice commands on (`QuizViewModel.enableVoiceCommands`,
    /// which raises the prompt and reports `voice_commands_turned_on`).
    private let enableCommands: @MainActor () async -> Void

    init(
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        analytics: AnalyticsClient = NoopAnalyticsClient(),
        consentDefaults: UserDefaults = .standard,
        enableCommands: @escaping @MainActor () async -> Void
    ) {
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.analytics = analytics
        self.consentDefaults = consentDefaults
        self.enableCommands = enableCommands
    }

    /// First-launch gate: present onboarding only while the persisted flag is unset.
    static func shouldPresentOnFirstLaunch(persistenceStore: PersistenceStoreProtocol) -> Bool {
        !persistenceStore.hasCompletedOnboarding
    }

    /// Page-indicator index. The denied page replaces the microphone page's
    /// outcome, so it stays on the first dot.
    var pageIndex: Int {
        switch page {
        case .microphone, .permissionDenied: 0
        case .commands: 1
        }
    }

    var pageCount: Int { 2 }

    /// The three command words on the commands page's card, in the command
    /// language — real words from the lexicon, never a made-up example.
    static func commandWords(language: CommandLanguage) -> [String] {
        VoiceCommandLexicon.spokenChips([.next, .repeatQuestion, .start], language: language)
    }

    /// "Allow" on the microphone page: granted → the commands page; refused →
    /// the denied page.
    func requestMicPermission() async {
        recordAIConsentIfOnMicrophonePage()
        micPermissionGranted = await audioService.requestMicrophonePermission()
        page = micPermissionGranted ? .commands : .permissionDenied
    }

    /// "Maybe later" on the microphone page, or leaving the denied page.
    /// Either way there is no mic, so the commands page is skipped.
    func continueWithoutMic() {
        recordAIConsentIfOnMicrophonePage()
        let outcome: OnboardingOutcome = page == .permissionDenied ? .micDenied : .micLater
        finish(outcome)
    }

    /// "Turn on commands": ask, then finish whatever the answer — a refusal
    /// shows up later as the listen bar's "Settings" button, never a dead end
    /// here.
    func turnOnCommands() async {
        guard page == .commands, !isEnablingCommands else { return }
        isEnablingCommands = true
        await enableCommands()
        isEnablingCommands = false
        finish(.commandsOn)
    }

    /// "Not now" on the commands page.
    func skipCommands() {
        guard page == .commands else { return }
        finish(.commandsLater)
    }

    /// Replay entry point (Settings row, 52.9). Restarts the flow without clearing
    /// or consulting `hasCompletedOnboarding` — founder decision 2026-06-11.
    func startOnboarding() {
        page = .microphone
        isComplete = false
        micPermissionGranted = false
    }

    /// #209 (guideline 5.1.2(i)): the microphone page shows the AI services
    /// disclosure above both of its buttons (#237 moved it there from the
    /// retired welcome page), so leaving it by either button is the consent.
    private func recordAIConsentIfOnMicrophonePage() {
        guard page == .microphone else { return }
        AIProcessingConsent.record(defaults: consentDefaults)
    }

    private func finish(_ outcome: OnboardingOutcome) {
        persistenceStore.completeOnboarding()
        isComplete = true
        analytics.track(.onboardingFinished(outcome: outcome, step: String(describing: page)))
    }
}
