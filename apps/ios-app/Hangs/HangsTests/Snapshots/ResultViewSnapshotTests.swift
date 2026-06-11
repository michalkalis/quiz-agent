//
//  ResultViewSnapshotTests.swift
//  HangsTests
//
//  Task 5 (issue #31): .dump snapshot baselines for two structurally-distinct
//  variants of ResultView.
//
//  Chosen variants and rationale:
//
//  A. correctVariant — evaluation.isCorrect == true.
//     "NAILED" substring present in heroBlock headline.
//     "result.continue" footer button present.
//
//  B. incorrectVariant — evaluation.isCorrect == false.
//     "CLOSE" substring present in heroBlock headline.
//
//  IMPORTANT: Both variants are captured BEFORE .onAppear fires, so
//  `showEvaluation` is false and the answerCard/statsRow guarded by
//  `if showEvaluation, viewModel.resultEvaluation != nil` are NOT in the dump.
//  Assertions intentionally target only always-rendered heroBlock content.
//
//  Strategy: .dump only — no image rendering; stable across simulator versions.
//

import Foundation
@testable import Hangs
import SnapshotTesting
import Testing

// MARK: - Helpers

/// Build a QuizViewModel in .showingResult for the given evaluation.
@MainActor
private func makeResultViewModel(evaluation: Evaluation) -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: MockNetworkService(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore()
    )
    // Use a fixed epoch so the dump output is stable across runs.
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    vm.currentSession = QuizSession(
        id: "test_sess",
        mode: "single",
        phase: "asking",
        maxQuestions: 10,
        currentDifficulty: "medium",
        category: nil,
        language: "en",
        participants: [],
        expiresAt: fixedNow.addingTimeInterval(30 * 60),
        createdAt: fixedNow
    )
    vm.currentQuestion = Question.preview
    vm.questionsAnswered = 1
    vm.quizState = .showingResult(question: Question.preview, evaluation: evaluation)
    return vm
}

// MARK: - Suite

@Suite("ResultView Snapshot Tests")
@MainActor
struct ResultViewSnapshotTests {
    // MARK: - Variant A: correct answer

    /// ResultView with a correct evaluation.
    /// Structural assertions (verified via dump baseline):
    ///   • "result.continue" footer button present (always rendered, no @State gate)
    ///   • "NAILED" substring present in heroBlock headline Text
    @Test("Snapshot: correct evaluation renders NAILED headline and continue button")
    func correctVariant() {
        let view = ResultView(viewModel: makeResultViewModel(evaluation: .previewCorrect))
        assertSnapshot(of: view, as: .stableDump)
    }

    // MARK: - Variant B: incorrect answer

    /// ResultView with an incorrect evaluation.
    /// Structural assertions (verified via dump baseline):
    ///   • "MISSED" substring present in heroBlock headline Text ("MISSED\nIT.")
    ///
    /// answerCard and statsRow gated behind `showEvaluation` (@State = false at
    /// struct init time) are NOT asserted here — see ResultViewInspectorTests for
    /// runtime-state assertions.
    @Test("Snapshot: incorrect evaluation renders MISSED headline")
    func incorrectVariant() {
        let view = ResultView(viewModel: makeResultViewModel(evaluation: .previewIncorrect))
        assertSnapshot(of: view, as: .stableDump)
    }
}
