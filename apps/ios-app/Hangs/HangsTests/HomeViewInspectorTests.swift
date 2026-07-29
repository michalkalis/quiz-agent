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
import Testing
import ViewInspector

@Suite("HomeView ViewInspector Tests")
@MainActor
struct HomeViewInspectorTests {
    private func makeViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
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

    @Test("Home still renders the session section and Start Quiz CTA")
    func homeKeepsSessionConfigAndCta() async throws {
        let view = HomeView(viewModel: makeViewModel())

        try await ViewHosting.host(view) {
            let tree = try view.inspect()

            #expect(throws: Never.self) {
                try tree.find(text: "session")
            }
            #expect(throws: Never.self) {
                try tree.find(button: "Start Quiz")
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
}
