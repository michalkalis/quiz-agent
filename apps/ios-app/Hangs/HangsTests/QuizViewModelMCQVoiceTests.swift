//
//  QuizViewModelMCQVoiceTests.swift
//  HangsTests
//
//  Issue #45 task 45.3: an MCQ question must be answerable by voice — the
//  think window and auto-record must start for it like for an open question.
//
//  #208.8: the on-device MCQ transcript routing (realtime STT committed
//  transcript → `MCQTranscriptMatcher` → sheet prefill) is gone with the
//  realtime path; an MCQ voice answer is uploaded and graded by the backend
//  like any other (see AnswerPipelineTests). `MCQTranscriptMatcherTests` keeps
//  the matcher itself covered while its future is decided.
//
//  Branches under test:
//    QuizViewModel.swift startRecordingOrTimer()                — guard removed
//

import Foundation
@testable import Hangs
import Testing

// MARK: - Local helpers

/// A 4-option MCQ question. Values are chosen so "Jupiter" is an unambiguous
/// value match and "béčko" an unambiguous letter-name match — both → key "b".
@MainActor
private func makeMCQQuestion() -> Question {
    Question(
        id: "q_mcq_001",
        question: "Largest planet?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
        difficulty: "medium",
        topic: "Astronomy",
        category: "science",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )
}

// MARK: - Suite

@Suite("QuizViewModel MCQ Voice Tests")
@MainActor
struct QuizViewModelMCQVoiceTests {
    // MARK: - Test 5: guard removal — recording no longer short-circuited for MCQ

    /// Regression: re-introducing any `isMultipleChoice != true` guard would make
    /// `startRecordingOrTimer` bail for MCQ, so the think window never starts,
    /// auto-record never opens the mic and the question can't be answered by
    /// voice. With the guard removed it starts the think window.
    @Test("startRecordingOrTimer starts the think window for an MCQ question")
    func mcqRecordingNotShortCircuited() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = makeMCQQuestion()
        viewModel.quizState = .askingQuestion

        viewModel.startRecordingOrTimer()

        await pumpUntil({ viewModel.thinkingTimeCountdown > 0 }, "the MCQ question got no think window")
        viewModel.quizTimersController.cancelThinkingTime()
    }
}
