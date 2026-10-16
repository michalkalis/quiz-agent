//
//  QuizViewModelSubmissionRaceTests.swift
//  HangsTests
//
//  Issue #79: a TYPED answer submitted while a voice answer is still in flight
//  (its upload not yet back) must NOT (a) grade twice, nor (b) resurrect the
//  voice confirmation sheet with the stale voice transcript. Since #186 every
//  submit path begins a new attempt and the voice upload's write-back checks
//  it still owns the attempt. #208.8: the only voice path is the batch upload
//  (record → VAD silence → `submitVoiceAnswer`), so the race is driven there,
//  with the upload parked on `MockNetworkService.submitVoiceAnswerGate`.
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) for deterministic scheduling.
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

// MARK: - Helpers

/// One-shot async gate: holds the mocked voice upload in flight.
private actor UploadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// ViewModel + mocks on the batch voice path, seeded at .askingQuestion. A
/// TestClock nobody advances: no recording window or submit bound can fire
/// on its own, only the test's events move the flow.
@MainActor
private func makeBatchViewModel()
    -> (QuizViewModel, MockNetworkService, MockAudioService, MockSilenceDetectionService) {
    let mockNetwork = Fixtures.makeFullMockNetwork()
    let mockAudio = MockAudioService()
    let silence = MockSilenceDetectionService()

    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: mockAudio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        clock: AnyClock(TestClock())
    )
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion
    viewModel.quizMuteOverride = true // no read-back: the sheet opens at once
    return (viewModel, mockNetwork, mockAudio, silence)
}

/// Record a spoken answer and let the VAD end it, as in the car: the silence
/// after speech stops the recording and starts the upload.
@MainActor
private func speakAnswer(_ viewModel: QuizViewModel, _ silence: MockSilenceDetectionService) async {
    await viewModel.recordingCoordinator.startRecording()
    await pumpUntil({ silence.isAnswerCaptureActive }, "answer capture never armed")
    silence.simulateAnswerAudio(Data(count: 16000))
    silence.simulateSilenceEvent(.speechStarted)
    silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.5))
}

/// Let a just-resumed handler run its (aborting) tail before we assert.
@MainActor
private func drainHops() async {
    for _ in 0 ..< 30 { await Task.yield() }
}

// MARK: - Suite

@Suite("QuizViewModel Submission Race Tests (#79)", .serialized)
@MainActor
struct QuizViewModelSubmissionRaceTests {

    // MARK: - (a) In-flight voice upload

    /// #79 acceptance: a typed answer submitted while the voice upload is still
    /// in flight must win — exactly one grading (the typed one), the sheet
    /// stays dismissed, and the stale voice text never lands on it.
    @Test("typed answer during an in-flight voice upload yields one grading and no stale sheet")
    func typedAnswerWinsVoiceUploadRace() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, silence) = makeBatchViewModel()
            let gate = UploadGate()
            mockNetwork.submitVoiceAnswerGate = { await gate.wait() }

            await speakAnswer(viewModel, silence)
            await pumpUntil({ mockNetwork.submitVoiceAnswerCallCount == 1 }, turns: 2000, "the upload never started")

            // Typed answer races in while the voice answer is with the server.
            await viewModel.resubmitAnswer("London")
            #expect(viewModel.quizState.isShowingResult)

            // The voice upload returns late — its result must be dropped.
            await gate.open()
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "London")
            #expect(viewModel.showAnswerConfirmation == false)
            #expect(viewModel.transcribedAnswer != "Test", "the stale voice transcript resurfaced")
            #expect(viewModel.quizState.isShowingResult)
        }
    }

    // MARK: - (c) Sheet-dismiss

    /// #79 acceptance: when the voice confirmation sheet is already up (upload
    /// fully processed), a typed answer dismisses it and submits exactly once.
    @Test("typed answer while the confirmation sheet is up dismisses it and submits once")
    func typedAnswerDismissesConfirmationSheet() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, silence) = makeBatchViewModel()

            await speakAnswer(viewModel, silence)
            await pumpUntil({ viewModel.showAnswerConfirmation }, turns: 2000, "confirmation sheet never appeared")
            #expect(mockNetwork.submitTextInputCallCount == 0) // sheet only, nothing graded via /input

            await viewModel.resubmitAnswer("London") // typed
            await pumpUntil({ viewModel.quizState.isShowingResult }, "typed submit never completed")

            #expect(viewModel.showAnswerConfirmation == false)
            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "London")
        }
    }

    // MARK: - (d) Normal voice flow unaffected

    /// #79 regression guard: with NO typed interference nothing supersedes the
    /// attempt, so the upload's transcript surfaces on the sheet and nothing is
    /// graded until the user confirms.
    @Test("a voice answer with no typed interference shows the sheet with the voice text")
    func normalVoiceFlowUnaffected() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, silence) = makeBatchViewModel()

            await speakAnswer(viewModel, silence)
            await pumpUntil({ viewModel.showAnswerConfirmation }, turns: 2000, "confirmation sheet never appeared")

            #expect(viewModel.quizState == .processing)
            #expect(viewModel.transcribedAnswer == "Test")
            // (The sheet may arm its own capture for a spoken replacement, #185 5.1,
            // so the capture state is not asserted here.)
            #expect(mockNetwork.submitVoiceAnswerCallCount == 1, "exactly one upload for one answer")
            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }

    // MARK: - (g) confirmAnswer() double-submit on the Whisper path (#100.2 follow-up)

    /// Seeds the Whisper (non-streaming) confirmation state exactly as
    /// submitRecordedAnswer leaves it (iOS 18–25, or an iOS 26 STT-init
    /// failure): cached pendingResponse, transcript shown, sheet up.
    private func seedWhisperConfirmation(
        _ viewModel: QuizViewModel, _ mockNetwork: MockNetworkService
    ) throws {
        viewModel.quizState = .processing
        viewModel.recordingCoordinator.pendingResponse = try #require(mockNetwork.mockResponse)
        viewModel.transcribedAnswer = "Paris"
        viewModel.showAnswerConfirmation = true
    }

    /// #100.2 follow-up: on the Whisper path the winner consumes
    /// pendingResponse and suspends in handleQuizResponse; the loser sees
    /// pendingResponse == nil and falls through to the streaming tail. Pre-fix
    /// (clear only in the tail) it still found the stale transcript there and
    /// POSTed it — scored against the next question. Capture-then-clear on
    /// entry makes the loser a no-op: zero /input submissions.
    @Test("Whisper path: concurrent confirmAnswer calls never resubmit the stale transcript")
    func doubleConfirmAnswerOnWhisperPathDoesNotResubmit() async throws {
        try await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, _) = makeBatchViewModel()
            try seedWhisperConfirmation(viewModel, mockNetwork)

            async let first: Void = viewModel.confirmAnswer()
            async let second: Void = viewModel.confirmAnswer()
            _ = await (first, second)
            await drainHops()

            await pumpUntil({ viewModel.quizState.isShowingResult }, "Whisper response never resolved")
            // The cached Whisper response resolves locally — no /input POST ever.
            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }

    /// #100.2 follow-up, stray-late variant: after the Whisper confirm fully
    /// resolved, a delayed confirmAnswer() must not resubmit the transcript
    /// (showingResult → processing is a legal transition, so only the cleared
    /// transcript stops it).
    @Test("Whisper path: a stray confirmAnswer after resolution does not resubmit the stale transcript")
    func staleConfirmAnswerOnWhisperPathDoesNotResubmit() async throws {
        try await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, _) = makeBatchViewModel()
            try seedWhisperConfirmation(viewModel, mockNetwork)

            await viewModel.confirmAnswer()
            await pumpUntil({ viewModel.quizState.isShowingResult }, "Whisper response never resolved")

            await viewModel.confirmAnswer() // stray/delayed second call
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }
}
