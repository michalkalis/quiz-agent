//
//  QuizViewModelMCQVoiceTests.swift
//  HangsTests
//
//  Issue #45 task 45.3: the MCQ voice path. A committed STT transcript on a
//  multiple-choice question must resolve through `MCQTranscriptMatcher` and
//  submit the matched option **value** via the text-input endpoint, instead of
//  being short-circuited (the old `isMultipleChoice != true` guards) or routed
//  to the tap-only confirmation modal. An unrecognized transcript must still
//  fall back to the modal so the driver can re-record rather than submit a guess.
//
//  Branches under test:
//    QuizViewModel+Recording.swift handleCommittedTranscript(_:) — MCQ routing
//    QuizViewModel.swift submitMCQAnswer(key:value:)            — value submit
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

/// Seed an MCQ question mid-recording so `handleCommittedTranscript` proceeds
/// past its `quizState == .recording` guard.
@MainActor
private func makeViewModelRecordingMCQ() -> (QuizViewModel, MockNetworkService) {
    let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = makeMCQQuestion()
    viewModel.quizState = .recording
    return (viewModel, mockNetwork)
}

// MARK: - Suite

@Suite("QuizViewModel MCQ Voice Tests")
@MainActor
struct QuizViewModelMCQVoiceTests {
    // MARK: - Test 1: spoken answer value → submit that value

    /// Regression: if the matcher routing is dropped, a driver saying the answer
    /// text on an MCQ would hit the tap-only modal and never submit hands-free.
    @Test("committed transcript matching an option value submits that value")
    func valueMatchSubmitsValue() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.handleCommittedTranscript("Jupiter")

        #expect(mockNetwork.capturedTextInputInput == "Jupiter")
        // submitMCQAnswer transitions .recording → .processing → (network) result.
        #expect(viewModel.quizState.isShowingResult)
        #expect(viewModel.showAnswerConfirmation == false)
    }

    // MARK: - Test 2: spoken letter name → submit the matched option's value

    /// Regression: the Slovak letter-name path ("béčko" → option b) must resolve
    /// to the option *value* ("Jupiter"), since the backend MCQ fast-path matches
    /// the value, not the spoken letter.
    @Test("committed transcript matching a letter name submits the option value")
    func letterMatchSubmitsValue() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.handleCommittedTranscript("béčko")

        #expect(mockNetwork.capturedTextInputInput == "Jupiter")
        #expect(viewModel.quizState.isShowingResult)
    }

    // MARK: - Test 3: unrecognized transcript → fall back to confirmation modal

    /// Regression: a wrong/ambiguous transcript must NOT auto-submit a guess —
    /// it falls through to the existing modal so the driver can re-record.
    @Test("unrecognized transcript falls back to the confirmation modal, no submit")
    func noMatchFallsBackToModal() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.handleCommittedTranscript("something entirely unrelated zzz")

        #expect(mockNetwork.capturedTextInputInput == nil)
        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer == "something entirely unrelated zzz")
    }

    // MARK: - Test 4: guard removal — recording no longer short-circuited for MCQ

    /// Regression: re-introducing any `isMultipleChoice != true` guard would make
    /// `startRecordingOrTimer` bail for MCQ, so the answer timer never starts and
    /// the question can't be answered by voice. With the guard removed it starts
    /// the answer timer (silenceDetectionService is nil → timer, not auto-record).
    @Test("startRecordingOrTimer starts the answer timer for an MCQ question")
    func mcqRecordingNotShortCircuited() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = makeMCQQuestion()
        viewModel.quizState = .askingQuestion

        viewModel.startRecordingOrTimer()

        #expect(viewModel.answerTimerCountdown > 0)
    }
}
