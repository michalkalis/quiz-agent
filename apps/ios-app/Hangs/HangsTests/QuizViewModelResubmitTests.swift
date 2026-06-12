//
//  QuizViewModelResubmitTests.swift
//  HangsTests
//
//  Task 3.3 (issue #31): covers the `resubmitAnswer` text path when
//  `transcriptWasEdited = true` (the "edited transcript → silent resubmit"
//  branch). New file required by the ~300-line file-size limit — the existing
//  QuizViewModelTests.swift was already 1188 lines (audit A2-6).
//
//  Branch under test:
//    QuizViewModel+Recording.swift:401-418  – confirmAnswer() snapshots
//      `silent = transcriptWasEdited` then calls resubmitAnswer(suppressAudio:)
//    QuizViewModel.swift:598-644            – resubmitAnswer passes
//      `audio: !suppressAudio && settings.audioMode != "off"`
//    QuizViewModel+Recording.swift:429-434  – beginEditingTranscript() sets
//      transcriptWasEdited = true
//

import Foundation
import Testing
@testable import Hangs

// MARK: - Local helpers

/// Seed the minimum state `resubmitAnswer` needs: an active session,
/// a question in flight, and state that lets the function proceed without
/// an early guard exit.
@MainActor
private func makeViewModelForResubmit(
    configure: (MockNetworkService) -> Void = { _ in }
) -> (QuizViewModel, MockNetworkService) {
    let (viewModel, mockNetwork) = Fixtures.makeViewModelWithNetwork(configure: configure)
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion
    return (viewModel, mockNetwork)
}

// MARK: - Suite

@Suite("QuizViewModel Resubmit Answer Tests")
@MainActor
struct QuizViewModelResubmitTests {

    // MARK: - Test 1: suppressAudio:true → audio:false

    /// Regression: a refactor that swaps the inverted boolean (`!suppressAudio`)
    /// would start replaying TTS on typed edited answers — surprising for a user
    /// who silently edited while driving.
    @Test("resubmitAnswer with suppressAudio:true passes audio:false to network")
    func resubmitSuppressedPassesAudioFalse() async throws {
        let (viewModel, mockNetwork) = makeViewModelForResubmit()

        await viewModel.resubmitAnswer("Paris", suppressAudio: true)

        #expect(mockNetwork.capturedTextInputAudio == false)
    }

    // MARK: - Test 2: suppressAudio:false + audioMode != "off" → audio:true

    /// Regression: breaks the normal voice-confirm flow — no TTS replay when
    /// the user confirms an un-edited voice transcript.
    @Test("resubmitAnswer with suppressAudio:false passes audio:true when audioMode is not off")
    func resubmitUnsuppressedPassesAudioTrueWhenAudioEnabled() async throws {
        let (viewModel, mockNetwork) = makeViewModelForResubmit()
        // Default audioMode is "media" — any value other than "off" enables audio.
        viewModel.settings.audioMode = "media"

        await viewModel.resubmitAnswer("Berlin", suppressAudio: false)

        #expect(mockNetwork.capturedTextInputAudio == true)
    }

    // MARK: - Test 3: suppressAudio:false + audioMode == "off" → audio:false

    /// Regression: the silent-mode setting being ignored on resubmit. The
    /// formula is `!suppressAudio && audioMode != "off"` — both flags must
    /// hold for audio to be enabled.
    @Test("resubmitAnswer with suppressAudio:false passes audio:false when audioMode is off")
    func resubmitUnsuppressedPassesAudioFalseWhenAudioOff() async throws {
        let (viewModel, mockNetwork) = makeViewModelForResubmit()
        viewModel.settings.audioMode = "off"

        await viewModel.resubmitAnswer("London", suppressAudio: false)

        #expect(mockNetwork.capturedTextInputAudio == false)
    }

    // MARK: - Test 4: End-to-end edited path

    /// Regression: any refactor of confirmAnswer() that either
    ///   (a) drops `silent = transcriptWasEdited` before passing to resubmitAnswer, or
    ///   (b) fails to clear `transcriptWasEdited` after snapshot (line 406),
    /// would either replay TTS unexpectedly or leave the flag set for the next answer.
    ///
    /// Setup mirrors the confirmation-sheet scenario:
    ///   commitedTranscript → .processing + showAnswerConfirmation
    ///   user taps pencil → beginEditingTranscript()
    ///   user taps Confirm → confirmAnswer()
    @Test("beginEditingTranscript then confirmAnswer submits with audio:false and resets transcriptWasEdited")
    func editedPathSubmitsSilentlyAndResetsFlag() async throws {
        let (viewModel, mockNetwork) = makeViewModelForResubmit()
        // Seed the transcript that confirmAnswer() will forward.
        viewModel.transcribedAnswer = "Paris"
        // Simulate being in the confirmation sheet state.
        viewModel.showAnswerConfirmation = true
        viewModel.quizState = .processing
        // pendingResponse must be nil so confirmAnswer() takes the streaming path.
        viewModel.pendingResponse = nil

        // User taps the pencil — this is the entry point for the "edited" branch.
        viewModel.beginEditingTranscript()
        #expect(viewModel.transcriptWasEdited == true)

        // User taps Confirm (without changing text — we're testing the flag, not editing).
        await viewModel.confirmAnswer()

        // The captured audio flag must be false (silent = transcriptWasEdited was true).
        #expect(mockNetwork.capturedTextInputAudio == false)
        // transcriptWasEdited must be reset so the next round starts clean.
        #expect(viewModel.transcriptWasEdited == false)
    }

    // MARK: - Test 5: Auto-confirm must not cancel its own submit (54.5)

    /// Regression: the auto-confirm Task used to `await confirmAnswer()` directly;
    /// confirmAnswer() starts with cancelAutoConfirm() → taskBag.cancel(.autoConfirm)
    /// → cancels the very Task it is running inside. The streaming-path submit
    /// (URLSession is cancellation-aware; the mock mirrors this) then throws
    /// URLError.cancelled → "Failed to resubmit answer: cancelled" OOPS screen
    /// instead of the result. The fix hands the confirm off to a fresh Task.
    @Test("auto-confirm fired countdown reaches showingResult, not error")
    func autoConfirmCountdownReachesShowingResult() async throws {
        let (viewModel, mockNetwork) = makeViewModelForResubmit()
        viewModel.settings.autoConfirmEnabled = true
        // Mirror the confirmation-sheet state after a committed streaming transcript.
        viewModel.transcribedAnswer = "Paris"
        viewModel.showAnswerConfirmation = true
        viewModel.quizState = .processing
        // pendingResponse nil → confirmAnswer() takes the streaming resubmit path.
        viewModel.pendingResponse = nil

        // Fire the real auto-confirm countdown (1s injected for test speed).
        viewModel.startAutoConfirmIfEnabled(duration: 1)

        // Countdown (1s) + handed-off submit; poll up to 4s.
        for _ in 0 ..< 40 where !viewModel.quizState.isShowingResult {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(viewModel.quizState.isShowingResult,
                "auto-confirm ended in \(viewModel.quizState) instead of showingResult")
        #expect(mockNetwork.capturedTextInputInput == "Paris")
    }

    // MARK: - Test 6: Happy-path state transition

    /// Regression: state-machine regression on the resubmit path — the ViewModel
    /// must reach .showingResult after a successful submitTextInput when
    /// suppressAudio:true (the existing resubmitAnswerSetsProcessing test in
    /// QuizViewModelTests.swift:320 covers the basic path; this one focuses
    /// on the terminal state specifically under the suppress-audio dimension).
    @Test("resubmitAnswer with suppressAudio:true transitions to showingResult on success")
    func resubmitSuppressedTransitionsToShowingResult() async throws {
        let (viewModel, _) = makeViewModelForResubmit()

        await viewModel.resubmitAnswer("Tokyo", suppressAudio: true)

        #expect(viewModel.quizState.isShowingResult)
    }
}
