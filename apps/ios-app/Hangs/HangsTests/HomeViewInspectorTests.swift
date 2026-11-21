//
//  HomeViewInspectorTests.swift
//  HangsTests
//
//  #84 (founder decision 5, Variant B): the whole Home stats row
//  (streak + best) is removed from the UI. QuizStats keeps computing —
//  only the display is gone. These tests pin that: the stat labels must
//  stay absent while the rest of the Home screen (session config card,
//  Start Quiz CTA) keeps rendering.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("HomeView ViewInspector Tests")
@MainActor
struct HomeViewInspectorTests {
    private func makeViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
        // Non-zero stats: the labels must be absent even when there IS a streak
        // to show — the row is gone by decision, not by empty data.
        vm.quizStats.recordAnswer(isCorrect: true)
        vm.quizStats.recordAnswer(isCorrect: true)
        return vm
    }

    @Test("Home renders no streak/best stat labels (#84 Variant B)")
    func homeHasNoStatsRow() async throws {
        let vm = makeViewModel()
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            // HangsStatBox labels are LocalizedStringKey — find(text:) matches
            // the source key. Neither stat label may render.
            #expect(throws: (any Error).self) {
                try tree.find(text: "streak")
            }
            #expect(throws: (any Error).self) {
                try tree.find(text: "best")
            }

            // Logic kept: stats still compute behind the scenes.
            #expect(vm.quizStats.currentStreak == 2)
            #expect(vm.quizStats.bestStreak == 2)
        }
    }

    // TestFlight build 90 (variant A1): the pills became one settings list
    // under the deck; the player must still reach every quiz setting (the
    // round length is new on Home), the categories and the Start CTA.
    @Test("Home still renders the session settings and Start Quiz CTA")
    func homeKeepsSessionConfigAndCta() async throws {
        let view = HomeView(viewModel: makeViewModel())

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            for id in ["home-language-menu", "home-difficulty-menu", "home.questionCount", "home.quickGame", "home.categories.chooseSeveral"] {
                #expect(throws: Never.self) {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            #expect(throws: Never.self) {
                try tree.find(button: "Start")
            }
        }
    }

    /// Quiz-start in-button loading: while `.startingQuiz` is in flight, the
    /// button must flip to a still-tappable "Cancel" control (`home.cancelStart`)
    /// instead of `Start Quiz` — `HangsPrimaryButton.isLoading` both spins AND
    /// disables, which would make an in-flight start uncancellable.
    @Test("Home shows a tappable Cancel control while a quiz start is in flight")
    func homeShowsCancelWhileStarting() async throws {
        let vm = makeViewModel()
        vm.quizState = .startingQuiz
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.cancelStart")
            }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "home.startQuiz")
            }

            // Must stay tappable (not `isLoading`, which disables the button) —
            // ViewInspector's `.tap()` throws if the button is disabled. Cancel's
            // downstream effect on `quizState` (landing on `.idle`) is covered by
            // the QuizViewModelTests cancellation tests, which drive a real
            // in-flight `beginQuizStart()` task.
            let cancelButton = try tree.find(viewWithAccessibilityIdentifier: "home.cancelStart").button()
            #expect(throws: Never.self) {
                try cancelButton.tap()
            }
        }
    }

    // MARK: - Listening bar (#131 Track F, Option B)

    /// Availability gating lives at the CALL SITE, not in the bar: the bar is
    /// rendered iff `commandListenerHint != nil` (window armed AND the recognizer
    /// ready). With no armed window — the default in these tests — Home must show
    /// no bar at all, so the app never claims to be listening when it is not.
    /// This is the gate the retired `CmdListenBar` carried on Home.
    @Test("Home renders no listening bar while no command window is armed")
    func homeHidesListenBarWhenNotListening() async throws {
        let vm = makeViewModel()
        let view = HomeView(viewModel: vm)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(vm.commandListenerHint == nil)
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }

    /// WHY (TestFlight build 90): Home had no way into Settings, so changing
    /// e.g. the round length meant finding the Profile tab. The gear must be
    /// there and must open Settings.
    @Test("Home's gear opens Settings")
    func gearOpensSettings() async throws {
        var opened = 0
        let view = HomeView(viewModel: makeViewModel(), onOpenSettings: { opened += 1 })

        try await ViewHosting.host(view) {
            // The gear is a navigation-bar item (after the logo): the tree
            // search does not enter the toolbar, so the test opens it there.
            let gear = try view.inspect().scrollView().toolbar().item(1).button()
            #expect(try gear.accessibilityIdentifier() == "home.settings")
            try gear.tap()
        }
        #expect(opened == 1)
    }

    /// WHY: at accessibility text sizes the deck and its "Choose several"
    /// hide, so the categories must get their own row in the list, or there
    /// is no way to pick one on Home.
    @Test("at accessibility text sizes the categories get a row in the list")
    func categoriesRowAtAccessibilitySizes() async throws {
        let view = HomeView(viewModel: makeViewModel())
            .environment(\.dynamicTypeSize, .accessibility2)

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home-categories-menu") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "home.categories.chooseSeveral") }
        }
    }

    /// WHY: the round length picked on Home is the one the next quiz plays,
    /// and the change is counted once (a re-pick of the same value is not).
    @Test("picking a round length on Home sets it and reports it once")
    func roundLengthFromHome() {
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            analytics: analytics
        )
        vm.setQuestionCount(15)
        vm.setQuestionCount(15)
        vm.settingsOpenedFromHome()
        #expect(vm.settings.numberOfQuestions == 15)
        #expect(analytics.events == [.homeRoundLengthChanged(questions: 15), .homeSettingsOpened])
    }
}
