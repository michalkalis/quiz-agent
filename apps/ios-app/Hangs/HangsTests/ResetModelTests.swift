//
//  ResetModelTests.swift
//  HangsTests
//
//  #113 T7 — the unified per-child reset() model. Pins the two mechanisms that
//  replaced resetState's scattered per-field writes: (a) full teardown invokes
//  every child's reset() + the two ownerless façade lines, so a phase
//  round-trip leaves ZERO residual across the ≥9 previously-missed fields;
//  (b) transition() drops the recording/confirmation subsets atomically when
//  leaving the recording/processing phase-pair — and never mid-pair.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("Unified reset model (#113 T7)")
struct ResetModelTests {
    /// WHY: before T7, resetState missed ≥9 fields (paywall, mic-picker,
    /// command capture, skip window, failure counter, auto-confirm, edit
    /// flags, error model, MCQ match) — each a sticky-state bug across quiz
    /// teardown. The per-child reset() mechanism must clear every one of them.
    @Test("full teardown leaves zero residual across all previously-missed fields")
    func resetStateClearsAllPreviouslyMissedFields() async throws {
        let viewModel = Fixtures.makeViewModel()

        // Seed every previously-missed field to a non-default value through
        // its public path.
        viewModel.showPaywall = true
        viewModel.quotaLimitError = QuotaLimitError(
            error: "quota_limit_reached",
            questionsUsed: 30,
            questionsLimit: 30,
            resetsAt: "2026-08-01T00:00:00Z",
            upgradeAvailable: true
        )
        viewModel.showingMicrophonePicker = true
        _ = viewModel.voiceCommandCoordinator.applyCaptureEvent(.arm)
        // The skip undo-window only opens while the question is being asked.
        viewModel.quizState = .askingQuestion
        viewModel.voiceCommandCoordinator.beginSkipUndoWindow()
        viewModel.consecutiveTranscriptionFailures = 2
        viewModel.autoConfirmCountdown = 5
        viewModel.recordingCoordinator.transcriptWasEdited = true
        viewModel.recordingCoordinator.preEditTranscript = "draft"
        viewModel.mcqVoiceMatchedKey = "b"
        viewModel.currentSession = Fixtures.session(score: 5.0, answered: 3)
        viewModel.answerTimerCountdown = 10
        viewModel.setError(message: "boom", context: .general)

        #expect(viewModel.voiceCommandCoordinator.commandCapturePhase == .armed)
        #expect(viewModel.voiceCommandCoordinator.pendingSkipWindow != nil)
        #expect(viewModel.activeErrorModel != nil)
        #expect(viewModel.score == 5.0)

        viewModel.resetToHome()

        #expect(viewModel.quizState == .idle)
        #expect(viewModel.showPaywall == false)
        #expect(viewModel.quotaLimitError == nil)
        #expect(viewModel.showingMicrophonePicker == false)
        #expect(viewModel.voiceCommandCoordinator.commandCapturePhase == .idle)
        #expect(viewModel.voiceCommandCoordinator.pendingSkipWindow == nil)
        #expect(viewModel.consecutiveTranscriptionFailures == 0)
        #expect(viewModel.autoConfirmCountdown == 0)
        #expect(viewModel.recordingCoordinator.transcriptWasEdited == false)
        #expect(viewModel.recordingCoordinator.preEditTranscript == nil)
        #expect(viewModel.activeErrorModel == nil)
        #expect(viewModel.mcqVoiceMatchedKey == nil)
        #expect(viewModel.score == 0.0)
        #expect(viewModel.questionsAnswered == 0)
        #expect(viewModel.answerTimerCountdown == 0)
    }

    /// WHY: decision 8 — phase state must drop atomically when the quiz leaves
    /// the recording/processing pair, but an in-pair move (recording →
    /// processing) must keep in-flight capture state or streaming submissions
    /// would lose their transcript.
    @Test("leaving the recording/processing pair drops both subsets; in-pair move keeps them")
    func leavingRecordingPairDropsPhaseState() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.liveTranscript = "hello"
        viewModel.speechDetectedDuringAutoRecord = true

        // In-pair move: recording → processing must NOT reset.
        #expect(viewModel.transition(to: .processing))
        #expect(viewModel.liveTranscript == "hello")
        #expect(viewModel.speechDetectedDuringAutoRecord == true)

        viewModel.transcribedAnswer = "Paris"
        viewModel.showAnswerConfirmation = true
        viewModel.autoConfirmCountdown = 3

        // Leaving the pair: processing → askingQuestion drops both subsets.
        #expect(viewModel.transition(to: .askingQuestion))
        #expect(viewModel.liveTranscript.isEmpty)
        #expect(viewModel.speechDetectedDuringAutoRecord == false)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.showAnswerConfirmation == false)
        #expect(viewModel.autoConfirmCountdown == 0)
    }

    /// WHY: score/questionsAnswered are derived from currentSession (#113 T7),
    /// which kills the stale-projection bug — "Play Again" from CompletionView
    /// calls startNewQuiz() without resetState(), and the stored counters used
    /// to carry the finished quiz's totals into the new quiz's first render.
    @Test("Play Again from .finished starts with zeroed derived counters")
    func playAgainZeroesDerivedCounters() async throws {
        let (viewModel, _) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.session(score: 8.5, answered: 10)
        viewModel.quizState = .finished
        #expect(viewModel.score == 8.5)

        await viewModel.startNewQuiz()

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.score == 0.0)
        #expect(viewModel.questionsAnswered == 0)
    }
}
