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

    /// WHY (#185 track B, founder decision 1.1, 2026-09-24): a miss must never
    /// end the question in silence. The first one is answered out loud — "I
    /// didn't catch that, say it again" — and the mic opens again at once. No
    /// sheet, no banner, no fresh think+answer countdown (#171 Track B's reason
    /// for deleting the old escalation still holds: that read as a broken timer).
    @Test("the first failed capture says it heard nothing and re-records — no sheet, no banner")
    func firstFailedCaptureRetries() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        (viewModel.audioService as? MockAudioService)?.playbackDurationNs = 0
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .recording

        viewModel.recordingCoordinator.handleTranscriptionFailure()

        #expect(viewModel.showAnswerConfirmation == false, "the first miss is not a sheet")
        #expect(viewModel.errorMessage == nil, "a banner re-reads as 'something broke, try again'")
        #expect(viewModel.isRerecording, "the bridge must not arm a fresh think/answer countdown")
        await pumpUntil({ viewModel.quizState == .recording }, "the retry never re-opened the mic")
        #expect(mockNetwork.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
    }

    /// WHY: one automatic retry, not a loop. The second miss on the same
    /// question hands the decision to the driver: the Again / Skip sheet, and
    /// NOTHING counting down on it — confirming an empty answer is a skip, and
    /// a skip is the driver's call (1.1). It also arrives unannounced (1.2 was
    /// rejected), so nothing more is spoken.
    @Test("the second failed capture opens the Again/Skip sheet with no countdown")
    func secondFailedCaptureOpensSheetWithoutCountdown() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        (viewModel.audioService as? MockAudioService)?.playbackDurationNs = 0
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.handleTranscriptionFailure()
        await pumpUntil({ viewModel.quizState == .recording }, "the retry never re-opened the mic")

        viewModel.recordingCoordinator.handleTranscriptionFailure()

        #expect(viewModel.showAnswerConfirmation == true)
        #expect(viewModel.noAnswerCaptured == true, "the sheet renders the no-answer body, not the Transcribing spinner")
        #expect(viewModel.transcribedAnswer.isEmpty)
        #expect(viewModel.quizState == .processing, "the sheet is a .processing screen, like every other confirmation")
        #expect(viewModel.taskBag.contains(.autoConfirm) == false, "no countdown may resolve this sheet")
        #expect(viewModel.autoConfirmCountdown == 0)
        #expect(viewModel.errorMessage == nil)
        #expect(mockNetwork.synthesizedTexts.count == 1, "the sheet is not announced")
    }

    /// WHY: the founder's exact TF trace — the answer window expires,
    /// auto-record opens, ElevenLabs commits dead air on its own. Dead air must
    /// take the same path as every other miss: the prompt and one re-record.
    @Test("empty spontaneous commit during auto-record takes the retry path")
    func emptyCommitDuringAutoRecordRetries() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.setIsAutoRecording(true)
        viewModel.recordingCoordinator.speechDetectedDuringAutoRecord = false

        await viewModel.recordingCoordinator.handleCommittedTranscript("")

        #expect(viewModel.showAnswerConfirmation == false)
        #expect(viewModel.isAutoRecording == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.taskBag.contains(.emptyAnswerRetry), "the retry is armed")
    }

    /// WHY: a spoken-but-lost answer (a content-bearing partial arrived, the
    /// commit came back empty) does not fork from dead air — one predictable
    /// path after every miss.
    @Test("empty commit after detected speech takes the same path")
    func emptyCommitAfterSpeechTakesSamePath() async throws {
        let viewModel = Fixtures.makeViewModel()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.setIsAutoRecording(true)
        viewModel.recordingCoordinator.speechDetectedDuringAutoRecord = true

        await viewModel.recordingCoordinator.handleCommittedTranscript("")

        #expect(viewModel.showAnswerConfirmation == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.taskBag.contains(.emptyAnswerRetry))
    }

    /// WHY: the Again/Skip sheet is only humane if Skip actually ends the
    /// question. Skip (and a spoken confirm) goes through `confirmAnswer()`,
    /// whose empty branch is "no answer" — it must reach a RESULT through the
    /// backend's skip contract, never strand the driver in `.processing`.
    @Test("skipping from the no-answer sheet submits no answer and reaches a result")
    func skippingFromNoAnswerSheetReachesResult() async throws {
        let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork()
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .recording
        viewModel.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        #expect(viewModel.noAnswerCaptured)

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
