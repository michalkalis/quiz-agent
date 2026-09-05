//
//  QuizViewModelMCQVoiceTests.swift
//  HangsTests
//
//  Issue #45 task 45.3 + #171 Track I: the MCQ voice path. A committed STT
//  transcript on a multiple-choice question must resolve through
//  `MCQTranscriptMatcher` and prefill the matched option **value** — not the raw
//  transcript, which the backend's value-matching MCQ evaluator would grade
//  wrong — into the confirmation sheet.
//
//  #171 Track I (founder 2026-09-05, restoring #45 decision D4) replaced the old
//  direct submit: a mishearing used to be graded before the driver could see it.
//  Every answer path now ends on the same confirmation sheet, so the correction
//  window exists for MCQ voice too. An unrecognized transcript still falls back
//  to the sheet with the RAW transcript, as before.
//
//  Branches under test:
//    RecordingCoordinator+Streaming.swift handleCommittedTranscript(_:) — MCQ routing
//    RecordingCoordinator+Confirmation.swift confirmAnswer()     — value submit
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
    // MARK: - Test 1: spoken answer value → confirmation sheet, prefilled

    /// #171 Track I: the match must NOT submit. It prefills the sheet so the
    /// driver sees what the app heard before it is graded — the whole point of
    /// the founder's "confirmation is mandatory for MCQ too" call. Nothing may
    /// reach the network until Confirm.
    @Test("committed transcript matching an option value opens the sheet prefilled with that value")
    func valueMatchOpensConfirmation() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.recordingCoordinator.handleCommittedTranscript("Jupiter")

        #expect(mockNetwork.capturedTextInputInput == nil, "an MCQ voice match must never submit before confirmation")
        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer == "Jupiter")
        #expect(viewModel.quizState == .processing)
    }

    /// #171 Track I: confirming is what submits — and it must submit the option
    /// VALUE, because the backend MCQ evaluator matches values with no LLM
    /// fallback (evaluator.py). A raw transcript would be graded wrong.
    @Test("confirming an MCQ voice match submits the option value and shows the result")
    func confirmingMCQVoiceMatchSubmitsValue() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()
        await viewModel.recordingCoordinator.handleCommittedTranscript("Jupiter")

        await viewModel.confirmAnswer()

        #expect(mockNetwork.capturedTextInputInput == "Jupiter")
        #expect(viewModel.quizState.isShowingResult)
        #expect(viewModel.showAnswerConfirmation == false)
    }

    // MARK: - Test 2: spoken letter name → the option's value, not the letter

    /// Regression: the Slovak letter-name path ("béčko" → option b) must prefill
    /// the option *value* ("Jupiter"). Prefilling "béčko" would send the letter
    /// to a value-matching evaluator and lose the point.
    @Test("committed transcript matching a letter name prefills the option value, not the letter")
    func letterMatchPrefillsValue() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.recordingCoordinator.handleCommittedTranscript("béčko")

        #expect(viewModel.transcribedAnswer == "Jupiter")
        #expect(mockNetwork.capturedTextInputInput == nil)
    }

    // MARK: - Test 3: unrecognized transcript → fall back to confirmation modal

    /// Regression: a wrong/ambiguous transcript must NOT be resolved to a guess
    /// — the sheet shows the RAW transcript so the driver can see the mishearing
    /// and re-record, unchanged by #171 Track I.
    @Test("unrecognized transcript falls back to the confirmation modal, no submit")
    func noMatchFallsBackToModal() async throws {
        let (viewModel, mockNetwork) = makeViewModelRecordingMCQ()

        await viewModel.recordingCoordinator.handleCommittedTranscript("something entirely unrelated zzz")

        #expect(mockNetwork.capturedTextInputInput == nil)
        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer == "something entirely unrelated zzz")
    }

    // MARK: - Test 4 (45.9): voice match sets mcqVoiceMatchedKey before submitting

    /// The AnswerOption `selected` highlight is driven by `mcqVoiceMatchedKey`,
    /// and since #171 Track I so is the sheet's "A · Kocka" line — one key, so
    /// the grid behind the sheet and the sheet itself can never disagree about
    /// which option is about to be graded.
    @Test("committed MCQ transcript sets mcqVoiceMatchedKey to the matched key")
    func voiceMatchSetsHighlightKey() async throws {
        let (viewModel, _) = makeViewModelRecordingMCQ()

        await viewModel.recordingCoordinator.handleCommittedTranscript("Jupiter")

        #expect(viewModel.mcqVoiceMatchedKey == "b")
        #expect(viewModel.showAnswerConfirmation == true)
    }

    // MARK: - Test 6 (#171 Track I): tolerant matching survives Slovak declension

    /// A driver saying "Jupitera" (genitive) means Jupiter. Exact matching missed
    /// every inflected form, so the raw transcript went to a value-matching
    /// evaluator and the answer was scored wrong.
    @Test("an inflected spoken answer still prefills the option value")
    func inflectedValueMatchPrefillsValue() async throws {
        let (viewModel, _) = makeViewModelRecordingMCQ()

        await viewModel.recordingCoordinator.handleCommittedTranscript("Jupitera")

        #expect(viewModel.mcqVoiceMatchedKey == "b")
        #expect(viewModel.transcribedAnswer == "Jupiter", "the sheet must carry the option value, not the inflected transcript")
    }

    // MARK: - Test 5: guard removal — recording no longer short-circuited for MCQ

    /// Regression: re-introducing any `isMultipleChoice != true` guard would make
    /// `startRecordingOrTimer` bail for MCQ, so the answer timer never starts and
    /// the question can't be answered by voice. With the guard removed it starts
    /// the answer timer (autoRecordEnabled off → timer, not auto-record).
    @Test("startRecordingOrTimer starts the answer timer for an MCQ question")
    func mcqRecordingNotShortCircuited() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = makeMCQQuestion()
        viewModel.quizState = .askingQuestion
        // #115: the service is always present now, so pin the legacy timer
        // branch explicitly — the guard-regression this test protects against
        // would zero the countdown in either branch.
        viewModel.settings.autoRecordEnabled = false

        viewModel.startRecordingOrTimer()

        #expect(viewModel.answerTimerCountdown > 0)
    }
}
