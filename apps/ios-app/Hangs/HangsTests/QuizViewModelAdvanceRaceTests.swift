//
//  QuizViewModelAdvanceRaceTests.swift
//  HangsTests
//
//  Issue #100.1: double-tap "Next" (ResultView continueToNext) or Next racing the
//  auto-advance timer both fire an untracked `Task { await proceedToNextQuestion() }`.
//  Before the fix, the guard `quizState.isShowingResult` is checked BEFORE two
//  `await`s (stopAnyPlayingAudio, a 100ms sleep) and the state only leaves
//  showingResult AFTER them — so two concurrent calls both pass the guard, and
//  the second one clobbers `currentQuestion`/`nextQuestion` set up by the first,
//  dead-ending the quiz loop with a nil currentQuestion.
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) for deterministic scheduling,
//  same technique as QuizViewModelSubmissionRaceTests (#79). Helpers below are
//  duplicated (not shared) to match that file's self-contained convention.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

/// Spin until `predicate` is true (sync @MainActor state).
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 10_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

/// Let just-resumed handlers run their tail before we assert.
@MainActor
private func drainHops() async {
    for _ in 0 ..< 20 { await Task.yield() }
}

// MARK: - Suite

@Suite("QuizViewModel Advance Race Tests (#100.1)")
@MainActor
struct QuizViewModelAdvanceRaceTests {

    /// #100.1 acceptance: two concurrent `proceedToNextQuestion()` calls (double-tap
    /// Next, or Next racing auto-advance) must leave exactly one advance — the
    /// second call is a silent no-op instead of clobbering state the first call
    /// already advanced. Pre-fix: both calls pass the `quizState.isShowingResult`
    /// guard (it's checked before the `stopAnyPlayingAudio`/sleep awaits, and state
    /// doesn't leave showingResult until after them), so the second call re-reads
    /// the private `nextQuestion` after the first has already nil-ed it, leaving
    /// `currentQuestion` nil and reproducing the "No question to evaluate"
    /// regression this bug caused downstream.
    @Test("two concurrent proceedToNextQuestion calls advance exactly once")
    func concurrentAdvanceCallsYieldOneAdvance() async throws {
        await withMainSerialExecutor {
            let mockNetwork = Fixtures.makeFullMockNetwork()
            let mockAudio = MockAudioService()
            let mockPersistence = MockPersistenceStore()
            let viewModel = QuizViewModel(
                networkService: mockNetwork,
                audioService: mockAudio,
                persistenceStore: mockPersistence
            )

            viewModel.currentSession = Fixtures.makeActiveSession() // not finished
            viewModel.currentQuestion = Fixtures.makeQuestion(id: "q_001")
            viewModel.quizState = .processing

            // `nextQuestion` is private to the ViewModel, so it can only be seeded
            // through the real path that sets it: handleQuizResponse. This also
            // transitions to .showingResult(...) exactly as the app does, matching
            // how QuizViewModelStreakTests seeds state via the same entry point.
            await viewModel.handleQuizResponse(QuizResponse(
                success: true,
                message: "Input processed",
                session: Fixtures.makeActiveSession(),
                currentQuestion: Fixtures.makeQuestion(id: "q_002"),
                evaluation: Evaluation(
                    userAnswer: "4",
                    result: .correct,
                    points: 1.0,
                    correctAnswer: "4",
                    questionId: "q_001",
                    explanation: nil
                ),
                feedbackReceived: [],
                audio: nil
            ))
            #expect(viewModel.quizState.isShowingResult) // sanity: seeding worked

            // Fire two concurrent calls without awaiting either individually first,
            // so they interleave deterministically at the internal suspension
            // points (stopAnyPlayingAudio / sleep) — the exact race window.
            async let a: Void = viewModel.proceedToNextQuestion()
            async let b: Void = viewModel.proceedToNextQuestion()
            _ = await (a, b)

            await waitUntil({ viewModel.quizState == .askingQuestion }, "never reached askingQuestion")
            await drainHops()

            #expect(viewModel.currentQuestion?.id == "q_002")
            #expect(viewModel.quizState == .askingQuestion)
            // The regression this bug caused: a subsequent answer-handling flow
            // guards on `currentQuestion` being non-nil ("No question to evaluate").
            #expect(viewModel.currentQuestion != nil)
        }
    }
}
