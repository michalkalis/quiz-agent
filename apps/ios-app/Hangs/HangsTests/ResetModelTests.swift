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
    /// command capture, skip window, no-answer flag, auto-confirm, edit
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
        viewModel.recordingCoordinator.noAnswerCaptured = true
        viewModel.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.mp3"
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
        #expect(viewModel.recordingCoordinator.noAnswerCaptured == false)
        #expect(viewModel.recordingCoordinator.currentQuestionAudioUrl == nil)
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
    /// would lose their transcript. Question-scoped fields must SURVIVE the
    /// exit: the question audio URL is replayed from .showingResult
    /// ("read aloud" / voice "repeat").
    @Test("leaving the recording/processing pair drops phase-scoped state; question-scoped state survives")
    func leavingRecordingPairDropsPhaseState() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.liveTranscript = "hello"
        viewModel.recordingCoordinator.speechDetectedDuringAutoRecord = true
        viewModel.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.mp3"

        // In-pair move: recording → processing must NOT reset.
        #expect(viewModel.transition(to: .processing))
        #expect(viewModel.liveTranscript == "hello")
        #expect(viewModel.recordingCoordinator.speechDetectedDuringAutoRecord == true)

        viewModel.transcribedAnswer = "Paris"
        viewModel.showAnswerConfirmation = true
        viewModel.autoConfirmCountdown = 3

        // Leaving the pair: processing → askingQuestion drops the capture +
        // confirmation subsets…
        #expect(viewModel.transition(to: .askingQuestion))
        #expect(viewModel.liveTranscript.isEmpty)
        #expect(viewModel.recordingCoordinator.speechDetectedDuringAutoRecord == false)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.showAnswerConfirmation == false)
        #expect(viewModel.autoConfirmCountdown == 0)
        // …while the question-scoped URL survives until success/teardown.
        #expect(viewModel.recordingCoordinator.currentQuestionAudioUrl == "https://example.com/q.mp3")
    }

    /// WHY (#171 Track B, founder 2026-09-05): the old 3-tier escalation
    /// answered an empty recording with a "Sorry, I didn't catch that" banner
    /// and a FRESH think+answer countdown — twice — before giving up. From the
    /// driver's seat that reads as a timer that will not end, and it was the
    /// most confusing behaviour of the TF round. A failed capture must instead
    /// land on the confirmation sheet with an EMPTY field: no banner, no new
    /// countdown, and the question is one Confirm away from a result.
    @Test("a failed capture opens the empty confirmation sheet instead of retrying")
    func failedCaptureOpensEmptyConfirmation() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording

        viewModel.recordingCoordinator.handleTranscriptionFailure()

        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.noAnswerCaptured == true, "the sheet must render the no-answer body, not the Transcribing spinner")
        #expect(viewModel.quizState == .processing, "the sheet is a .processing screen, like every other confirmation")
        #expect(viewModel.errorMessage == nil, "the empty sheet IS the message — a banner re-reads as 'try again'")
    }

    /// WHY: repetition was the bug. The second failure must behave exactly like
    /// the first — one sheet, still no countdown restart — rather than
    /// escalating through tiers the founder asked us to delete.
    @Test("a second failed capture behaves identically — no escalation tiers left")
    func repeatedFailedCaptureDoesNotEscalate() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.handleTranscriptionFailure()

        // Back to the question (a re-record), then fail again.
        viewModel.transition(to: .askingQuestion)
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.handleTranscriptionFailure()

        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.quizState == .processing)
    }

    /// WHY: the founder's exact TF trace — the answer window expires,
    /// auto-record opens, ElevenLabs commits dead air on its own. Dead air used
    /// to skip the question outright; it now gets the same empty sheet as every
    /// other miss, so the driver still has a beat to type or say "again" before
    /// it counts as no answer.
    @Test("empty spontaneous commit during auto-record opens the empty confirmation sheet")
    func emptyCommitDuringAutoRecordOpensConfirmation() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.setIsAutoRecording(true)
        viewModel.recordingCoordinator.speechDetectedDuringAutoRecord = false

        await viewModel.recordingCoordinator.handleCommittedTranscript("")

        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.noAnswerCaptured == true)
        #expect(viewModel.errorMessage == nil)
    }

    /// WHY: a spoken-but-lost answer (a content-bearing partial arrived, the
    /// commit came back empty) used to be the one case that earned a retry.
    /// It no longer forks: both misses end on the same sheet, which is what
    /// makes the flow predictable — one screen after every recording.
    @Test("empty commit after detected speech takes the same no-answer path")
    func emptyCommitAfterSpeechTakesSamePath() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.setIsAutoRecording(true)
        viewModel.recordingCoordinator.speechDetectedDuringAutoRecord = true

        await viewModel.recordingCoordinator.handleCommittedTranscript("")

        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    /// WHY: the empty sheet is only humane if Confirm actually ends the
    /// question. `confirmAnswer()` used to drop an empty answer on the floor —
    /// the sheet closed and the quiz sat in .processing forever. An empty
    /// confirm now means "no answer" and must reach a RESULT through the
    /// backend's existing skip contract.
    @Test("confirming an empty answer submits no answer and reaches a result")
    func confirmingEmptyAnswerReachesResult() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.handleTranscriptionFailure()

        await viewModel.confirmAnswer()

        #expect(mockNetwork.capturedTextInputInput == "skip", "no answer is submitted through the existing skip contract")
        #expect(viewModel.quizState.isShowingResult, "the driver must never be stranded in .processing")
        #expect(viewModel.showAnswerConfirmation == false)
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
