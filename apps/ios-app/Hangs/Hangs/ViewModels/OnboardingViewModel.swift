//
//  OnboardingViewModel.swift
//  Hangs
//
//  Onboarding navigation + mic-permission state machine — #52 task 52.5.
//  Welcome → Features → Permission → (granted → done | denied → permissionDenied).
//  Logic only; the Phase-3 onboarding views (52.13) bind to this.
//

import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Page: Int, Equatable, CaseIterable {
        case welcome = 0
        case features = 1
        case permission = 2
        /// 3b-Denied branch (frame COHnz) — reached only when the mic request is denied.
        case permissionDenied = 3
    }

    @Published private(set) var page: Page = .welcome
    /// True once the flow finishes (granted or continued from denied) — the host view dismisses on this.
    @Published private(set) var isComplete = false
    @Published private(set) var micPermissionGranted = false

    private let audioService: AudioServiceProtocol
    private let persistenceStore: PersistenceStoreProtocol
    private let analytics: AnalyticsClient
    private let consentDefaults: UserDefaults

    init(
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        analytics: AnalyticsClient = NoopAnalyticsClient(),
        consentDefaults: UserDefaults = .standard
    ) {
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.analytics = analytics
        self.consentDefaults = consentDefaults
    }

    /// First-launch gate: present onboarding only while the persisted flag is unset.
    static func shouldPresentOnFirstLaunch(persistenceStore: PersistenceStoreProtocol) -> Bool {
        !persistenceStore.hasCompletedOnboarding
    }

    /// Page-indicator index. The denied branch replaces the permission page, so both map to dot 2.
    var pageIndex: Int { min(page.rawValue, Page.permission.rawValue) }
    var pageCount: Int { 3 }

    /// Linear advance through the informational pages. The permission page resolves
    /// via `requestMicPermission()`, not `advance()`.
    func advance() {
        switch page {
        case .welcome:
            recordAIConsentIfOnWelcome()
            page = .features
        case .features: page = .permission
        case .permission, .permissionDenied: break
        }
    }

    /// Permission branch point: granted finishes the flow (→ Home); denied shows 3b-Denied.
    func requestMicPermission() async {
        micPermissionGranted = await audioService.requestMicrophonePermission()
        if micPermissionGranted {
            finish(.micGranted)
        } else {
            page = .permissionDenied
        }
    }

    /// Exit from the denied page without mic access (typed answers remain available).
    func continueWithoutMic() {
        recordAIConsentIfOnWelcome()
        let outcome: OnboardingOutcome = switch page {
        case .welcome, .features: .skipped
        case .permission: .micLater
        case .permissionDenied: .micDenied
        }
        finish(outcome)
    }

    /// Replay entry point (Settings row, 52.9). Restarts the flow without clearing
    /// or consulting `hasCompletedOnboarding` — founder decision 2026-06-11.
    func startOnboarding() {
        page = .welcome
        isComplete = false
        micPermissionGranted = false
    }

    /// #209 (guideline 5.1.2(i)): the welcome page shows the AI services
    /// disclosure above both of its buttons, so leaving it by Continue or Skip
    /// is the player's consent.
    private func recordAIConsentIfOnWelcome() {
        guard page == .welcome else { return }
        AIProcessingConsent.record(defaults: consentDefaults)
    }

    private func finish(_ outcome: OnboardingOutcome) {
        persistenceStore.completeOnboarding()
        isComplete = true
        analytics.track(.onboardingFinished(outcome: outcome, step: String(describing: page)))
    }
}
