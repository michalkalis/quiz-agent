//
//  HomeViewSnapshotTests.swift
//  HangsTests
//
//  Task 5 (issue #31): .dump snapshot baseline for HomeView.
//
//  Variant: idleWithStats
//  Uses a fresh per-test view model (askingQuestion state, default settings).
//  Captures the structural presence of HangsHeroBlock, HangsCard (config card),
//  HangsPrimaryButton, and the home.startQuiz accessibility identifier.
//
//  Strategy: .dump only — text mirror of view struct tree. No image rendering.
//

import Foundation
import SnapshotTesting
import Testing
@testable import Hangs

// MARK: - Helpers

/// Build a fresh QuizViewModel mirroring `QuizViewModel.preview`.
///
/// Deliberately NOT the shared `.preview` singleton: other suites in the same
/// process (e.g. the SettingsView hosted-inspector tests) subscribe to it,
/// which flips its `@Published` storage from `.value` to `.publisher` — the
/// dump then depends on suite ordering and flakes under the full run.
@MainActor
private func makeIdleViewModel() -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: MockNetworkService(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore()
    )
    vm.currentQuestion = Question.preview
    vm.quizState = .askingQuestion
    vm.settings.audioMode = AudioMode.default.id
    return vm
}

@Suite("HomeView Snapshot Tests")
@MainActor
struct HomeViewSnapshotTests {

    /// HomeView in its default idle-with-stats state.
    /// Confirms that:
    ///   • HangsHeroBlock is present in the view tree
    ///   • HangsCard (config card) appears in the tree
    ///   • HangsPrimaryButton is present (the Start Quiz CTA)
    ///   • The accessibility identifier "home.startQuiz" appears in the dump
    @Test("Snapshot: idle state with stats and config card")
    func idleWithStats() async {
        let view = HomeView(viewModel: makeIdleViewModel())
        assertSnapshot(of: view, as: .stableDump)
    }
}
