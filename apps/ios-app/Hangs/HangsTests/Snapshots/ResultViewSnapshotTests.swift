//
//  ResultViewSnapshotTests.swift
//  HangsTests
//
//  .dump snapshot baselines for two structurally-distinct variants of ResultView.
//  Re-recorded for issue #127 (Variant C "Zero-Scroll Deck"): the three fixed
//  zones replace the pinned-nav-above-ScrollView layout, so the baselines were
//  deleted and re-recorded.
//
//  Chosen variants and rationale:
//
//  A. correctVariant — evaluation.isCorrect == true. "NAILED" verdict word +
//     "result.continue" CTA present.
//
//  B. incorrectVariant — evaluation.isCorrect == false. "MISSED" verdict word.
//
//  Variant C removed the .onAppear content gate (nothing scrolls, so the answer
//  panel always renders); the dump captures the full struct topology.
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
        // Single participant pins the derived questionsAnswered = 1 (#113 T7 —
        // computed over currentSession). Built inline rather than via
        // Fixtures.session because the dump needs the fixed epoch for stability.
        participants: [
            Participant(
                id: "p1",
                userId: nil,
                displayName: "Player",
                score: 1.0,
                answeredCount: 1,
                correctCount: 1,
                lastAnswer: nil,
                lastResult: nil,
                isHost: true,
                isReady: true,
                joinedAt: fixedNow
            ),
        ],
        expiresAt: fixedNow.addingTimeInterval(30 * 60),
        createdAt: fixedNow
    )
    vm.currentQuestion = Question.preview
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
    ///   • "MISSED" verdict word present in the verdict field.
    ///
    /// Runtime-state assertions live in ResultViewInspectorTests.
    @Test("Snapshot: incorrect evaluation renders MISSED headline")
    func incorrectVariant() {
        let view = ResultView(viewModel: makeResultViewModel(evaluation: .previewIncorrect))
        assertSnapshot(of: view, as: .stableDump)
    }

    // MARK: - Variant C: skipped (#131 Track D)

    /// ResultView with a skipped evaluation.
    /// Structural assertions (verified via dump baseline):
    ///   • "SKIPPED." verdict word present, not "MISSED IT."
    ///   • no "you said" recap row (dropped for this state)
    @Test("Snapshot: skipped evaluation renders SKIPPED headline, no you-said row")
    func skippedVariant() {
        let evaluation = Evaluation(
            userAnswer: "", result: .skipped, points: 0.0,
            correctAnswer: "Uranus", questionId: "q_test", explanation: nil
        )
        let view = ResultView(viewModel: makeResultViewModel(evaluation: evaluation))
        assertSnapshot(of: view, as: .stableDump)
    }
}
