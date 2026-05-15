//
//  QuestionViewSnapshotTests.swift
//  HangsTests
//
//  Task 5 (issue #31): .dump snapshot baselines for two structurally-distinct
//  variants of QuestionView.
//
//  Chosen variants and rationale:
//
//  A. askingState — quizState == .askingQuestion with a question loaded.
//     The question prompt (HangsQuestionPrompt, a11y id: question.text) and mic
//     button (HangsMicBlock, a11y id: question.micButton) are present.
//     Status pill shows "READY" copy. Waveform Capsule shapes are NOT asserted
//     (only visible in recording state).
//
//  B. recordingState — quizState == .recording.
//     Status pill (a11y id: question.statusPill) is present and the
//     "RECORDING" substring appears in the dump because currentStatus.text
//     is captured by Mirror. Waveform shapes are NOT asserted (dynamic, capsule).
//
//  Strategy: .dump only — no image rendering; stable across simulator versions.
//

import Foundation
import SnapshotTesting
import Testing
@testable import Hangs

// MARK: - Helpers

/// Build a QuizViewModel in .askingQuestion with a pre-loaded question.
@MainActor
private func makeAskingViewModel() -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: MockNetworkService(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore()
    )
    vm.currentQuestion = Question.preview
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
    vm.quizState = .askingQuestion
    return vm
}

/// Build a QuizViewModel in .recording state.
@MainActor
private func makeRecordingViewModel() -> QuizViewModel {
    let vm = makeAskingViewModel()
    vm.quizState = .recording
    return vm
}

// MARK: - Suite

@Suite("QuestionView Snapshot Tests")
@MainActor
struct QuestionViewSnapshotTests {

    // MARK: - Variant A: askingQuestion state

    /// QuestionView with quizState == .askingQuestion.
    /// Structural assertions (verified by inspecting the dump baseline):
    ///   • "question.text" identifier present → HangsQuestionPrompt rendered
    ///   • "question.micButton" identifier present → HangsMicBlock rendered
    ///   • "READY" substring present in status pill copy
    @Test("Snapshot: asking-question state renders question prompt and mic button")
    func askingState() {
        let view = QuestionView(viewModel: makeAskingViewModel())
        assertSnapshot(of: view, as: .stableDump)
    }

    // MARK: - Variant B: recording state

    /// QuestionView with quizState == .recording.
    /// Structural assertions:
    ///   • "question.statusPill" identifier present
    ///   • "RECORDING" substring present in statusPill text (currentStatus.text
    ///     captured by Mirror reflection of QuizStatus.text property)
    ///
    /// Waveform Capsule shapes are NOT asserted — they are dynamic layout details
    /// with no stable string representation in .dump output.
    @Test("Snapshot: recording state renders status pill with RECORDING copy")
    func recordingState() {
        let view = QuestionView(viewModel: makeRecordingViewModel())
        assertSnapshot(of: view, as: .stableDump)
    }
}
